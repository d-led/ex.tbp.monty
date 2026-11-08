defmodule Monty.Studio.ReplayTest do
  use ExUnit.Case, async: true

  alias Monty.Studio.Replay
  alias Monty.Studio.RunHistory.Run

  # A run as the database keeps it: what each step saw, and what the modules
  # made of it. No database here — a replay is a function of the record.
  defp run(steps) do
    %Run{
      timeline: Enum.map(steps, &moment/1),
      log: Enum.map(steps, &entry/1)
    }
  end

  defp moment(step) do
    %{
      "step" => step,
      "sensors" => %{
        "patch" => %{"location" => [step * 0.01, 0.0, 0.1], "value" => step * 0.01},
        "view_finder" => %{"location" => [step * 0.01, 0.0, 0.11], "value" => step * 0.01}
      }
    }
  end

  defp entry(step) do
    %{
      "step" => step,
      "percepts" => ["patch"],
      "inputs" => %{"learning_module_0" => 1},
      "votes" => %{"sent" => 1, "used" => if(rem(step, 2) == 0, do: 1, else: 0)},
      "goals" => 1,
      "actions" => 1,
      "duration_us" => 100 + step
    }
  end

  # A run whose steps kept a picture per sensor, in the shape the database keeps:
  # the PNGs as they were drawn, and the depth range they were drawn over.
  defp with_pictures(steps) do
    %Run{
      timeline:
        Enum.map(steps, fn step ->
          %{
            "step" => step,
            "sensors" => %{
              "patch" => %{
                "location" => [step * 0.01, 0.0, 0.1],
                "images" => %{"depth" => "png", "range" => [0.02, 0.04]}
              },
              "view_finder" => %{
                "location" => [step * 0.01, 0.0, 0.11],
                "images" => %{"depth" => "png", "range" => [0.03, 0.05]}
              }
            }
          }
        end),
      log: Enum.map(steps, &entry/1)
    }
  end

  # A step's report with what the learning modules believed, in the shape the
  # database keeps: `max_evidence` under the object it is about.
  defp believe(entry, evidence) when is_number(evidence),
    do: believe(entry, %{"learning_module_0" => evidence})

  defp believe(entry, by_module) do
    beliefs =
      Map.new(by_module, fn {module, evidence} ->
        {module, %{"graphs" => %{"mug" => %{"max_evidence" => evidence}}}}
      end)

    Map.put(entry, "beliefs", beliefs)
  end

  describe "the steps a run recorded" do
    test "are the steps the timeline has, in order" do
      assert Replay.steps(run(0..2)) == [0, 1, 2]
      assert Replay.first_step(run(0..2)) == 0
      assert Replay.last_step(run(0..2)) == 2
    end

    test "are none for a run that has not stepped yet" do
      empty = %Run{timeline: [], log: []}

      assert Replay.steps(empty) == []
      assert Replay.first_step(empty) == nil
      assert Replay.last_step(empty) == nil
      assert Replay.at(empty, 0) == nil
    end
  end

  describe "one step of a replay" do
    test "is the frame that run saw, not a new one" do
      moment = Replay.at(with_pictures(0..3), 2)

      assert moment.step == 2
      assert moment.frames |> Enum.map(& &1.sensor_id) |> Enum.sort() == ["patch", "view_finder"]

      # The note is the range the step was drawn over, read back from the record:
      # the frame is history, not a re-simulation of it.
      assert moment.frames |> Enum.find(&(&1.sensor_id == "patch")) |> Map.get(:note) =~
               "depth 0.020–0.040 m"
    end

    test "a step whose sensors kept no picture has no frames to draw" do
      # A run recorded before runs kept their pictures, or one whose sensors are
      # not cameras: the page says so once instead of drawing blank boxes.
      assert Replay.at(run(0..3), 2).frames == []
      refute Replay.pictures?(run(0..3))
    end

    test "carries the report the modules gave at the same step" do
      moment = Replay.at(run(0..3), 3)

      assert moment.entry["votes"]["used"] == 0
      assert moment.entry["duration_us"] == 103
    end

    test "is the nearest recorded step when asked for one that never happened" do
      # A slider dragged past the end comes to rest at the end.
      assert Replay.at(run(0..3), 99).step == 3
      assert Replay.at(run(0..3), -5).step == 0
    end

    test "has no report when the log and the timeline disagree" do
      run = %Run{timeline: [moment(0)], log: []}

      assert %{entry: nil, step: 0} = Replay.at(run, 0)
    end
  end

  describe "the series a replay can chart" do
    test "start with what the sensors saw, in metres" do
      series = Replay.series(run(0..2))

      assert [%{id: "sensor:patch", unit: "m"}, %{id: "sensor:view_finder", unit: "m"} | _rest] =
               series

      assert series |> Enum.map(& &1.id) |> Enum.take(2) == ["sensor:patch", "sensor:view_finder"]

      assert Replay.chart_series(run(0..2), "sensor:patch").points == [
               %{step: 0, value: 0.0, episode: nil},
               %{step: 1, value: 0.01, episode: nil},
               %{step: 2, value: 0.02, episode: nil}
             ]
    end

    test "continue with what the modules made of it" do
      assert Replay.chart_series(run(0..1), "percepts").points == [
               %{step: 0, value: 1, episode: nil},
               %{step: 1, value: 1, episode: nil}
             ]

      assert Replay.chart_series(run(0..1), "votes_used").points == [
               %{step: 0, value: 1, episode: nil},
               %{step: 1, value: 0, episode: nil}
             ]

      assert Replay.chart_series(run(0..1), "duration_us").unit == "µs"
    end

    test "have a point for every step, even when the log is missing one" do
      run = %Run{timeline: [moment(0), moment(1)], log: [entry(0)]}

      assert Replay.chart_series(run, "percepts").points == [
               %{step: 0, value: 1, episode: nil},
               %{step: 1, value: 0, episode: nil}
             ]
    end

    test "show the evidence the run climbed to, which is how an episode is judged" do
      run = %Run{
        timeline: [moment(0), moment(1), moment(2)],
        log: [believe(entry(0), 0.5), believe(entry(1), 4.0), believe(entry(2), 9.5)]
      }

      assert %{label: "best evidence", unit: ""} = Replay.chart_series(run, "evidence")

      assert Replay.chart_series(run, "evidence").points == [
               %{step: 0, value: 0.5, episode: nil},
               %{step: 1, value: 4.0, episode: nil},
               %{step: 2, value: 9.5, episode: nil}
             ]
    end

    test "take the best evidence across the modules that reported" do
      run = %Run{
        timeline: [moment(0)],
        log: [believe(entry(0), %{"learning_module_0" => 1.0, "learning_module_1" => 7.0})]
      }

      assert Replay.chart_series(run, "evidence").points == [%{step: 0, value: 7.0, episode: nil}]
    end

    test "say a run believed nothing when no module believed anything" do
      assert Replay.chart_series(run(0..1), "evidence").points == [
               %{step: 0, value: 0.0, episode: nil},
               %{step: 1, value: 0.0, episode: nil}
             ]
    end

    test "find a sensor's place in the camera pose, for a world that sends no location" do
      # `cam_to_world`'s last column is where the camera was: the world behind
      # the port answers this and not `location`, and a chart of zeros would claim
      # the sensor never moved.
      camera = [
        [1.0, 0.0, 0.0, 0.5],
        [0.0, 1.0, 0.0, 1.5],
        [0.0, 0.0, 1.0, 0.08],
        [0.0, 0.0, 0.0, 1.0]
      ]

      run = %Run{
        timeline: [%{"step" => 0, "sensors" => %{"patch" => %{"cam_to_world" => camera}}}],
        log: [entry(0)]
      }

      assert Replay.chart_series(run, "sensor:patch").points == [
               %{step: 0, value: 0.5, episode: nil}
             ]
    end
  end

  describe "the window a chart draws" do
    test "is clamped to the steps the run has" do
      assert Replay.window(run(0..11), {-5, 99}) == {0, 11}
      assert Replay.window(run(0..11), {3, 7}) == {3, 7}
    end

    test "knows which steps are inside it" do
      assert Replay.inside?({3, 7}, 3)
      assert Replay.inside?({3, 7}, 7)
      refute Replay.inside?({3, 7}, 2)
      refute Replay.inside?({3, 7}, 8)
    end
  end

  describe "zooming" do
    test "in halves the window around the playhead, on whole steps" do
      assert Replay.zoom(run(0..11), {0, 11}, 6, :in) == {4, 9}
    end

    test "in stops at the ends instead of going past them" do
      assert Replay.zoom(run(0..11), {0, 11}, 0, :in) == {0, 5}
      assert Replay.zoom(run(0..11), {0, 11}, 11, :in) == {6, 11}
    end

    test "out doubles the window but never past the whole run" do
      assert Replay.zoom(run(0..11), {4, 6}, 5, :out) == {3, 7}
      assert Replay.zoom(run(0..11), {0, 8}, 4, :out) == {0, 11}
    end

    test "all goes back to the run" do
      assert Replay.zoom(run(0..11), {4, 6}, 5, :all) == {0, 11}
    end

    test "a run of one step cannot be zoomed into a hole" do
      # One recorded moment, whatever step number it carries: the replay's axis
      # is the run's own sequence, so its only position is 0.
      assert Replay.zoom(run([7]), {0, 0}, 0, :in) == {0, 0}
      assert Replay.zoom(run([7]), {0, 0}, 0, :out) == {0, 0}
    end
  end

  describe "the objects a run believed in" do
    # The values of the one line a chart holds, which is its shape.
    defp values([series]), do: Enum.map(series.points, & &1.value)

    # Two objects, one module each, evidence climbing for the object it guesses.
    defp with_graphs(steps) do
      %Run{
        timeline: Enum.map(steps, &moment/1),
        log:
          Enum.map(steps, fn step ->
            %{"step" => step}
            |> Map.put("beliefs", %{
              "learning_module_0" => %{
                "graphs" => %{
                  "mug" => %{"max_evidence" => step * 1.0},
                  "bowl" => %{"max_evidence" => 10 - step * 1.0}
                }
              }
            })
          end)
      }
    end

    test "one series per object, over every step" do
      series = Replay.objects(with_graphs(0..2))

      assert Enum.map(series, & &1.label) == ["bowl", "mug"]

      assert Enum.map(Enum.find(series, &(&1.label == "mug")).points, & &1.value) == [
               0.0,
               1.0,
               2.0
             ]
    end

    test "a theory the module culled ends where the module stopped holding it" do
      # Bowl is gone from step 2 onwards: the run ruled it out, so the chart must
      # end that line rather than carry it at zero and imply it was still in play.
      run = %Run{
        timeline: [moment(0), moment(1), moment(2)],
        log: [
          %{
            "step" => 0,
            "beliefs" => %{
              "learning_module_0" => %{
                "graphs" => %{
                  "mug" => %{"max_evidence" => 1.0},
                  "bowl" => %{"max_evidence" => 2.0}
                }
              }
            }
          },
          %{
            "step" => 1,
            "beliefs" => %{
              "learning_module_0" => %{
                "graphs" => %{
                  "mug" => %{"max_evidence" => 2.0},
                  "bowl" => %{"max_evidence" => 1.0}
                }
              }
            }
          },
          %{
            "step" => 2,
            "beliefs" => %{
              "learning_module_0" => %{"graphs" => %{"mug" => %{"max_evidence" => 3.0}}}
            }
          }
        ]
      }

      bowl = Enum.find(Replay.objects(run), &(&1.label == "bowl"))

      assert Enum.map(bowl.points, & &1.step) == [0, 1]
    end

    test "an object is as strong as the strongest module that held it" do
      record = %Run{
        timeline: Enum.map([0], &moment/1),
        log: [
          %{
            "step" => 0,
            "beliefs" => %{
              "learning_module_0" => %{"graphs" => %{"mug" => %{"max_evidence" => 1.5}}},
              "learning_module_1" => %{"graphs" => %{"mug" => %{"max_evidence" => 4.5}}}
            }
          }
        ]
      }

      assert [%{points: [%{value: 4.5}]}] = Replay.objects(record)
    end

    test "and one module's own chart is that module's answer, not the strongest" do
      # One heterarchy, two modules, one object: the ensemble's line is the best
      # of them, which is why it cannot say that the two disagreed.
      record = %Run{
        timeline: Enum.map([0, 1], &moment/1),
        log: [
          %{
            "step" => 0,
            "beliefs" => %{
              "learning_module_0" => %{"graphs" => %{"mug" => %{"max_evidence" => 1.5}}},
              "learning_module_1" => %{"graphs" => %{"mug" => %{"max_evidence" => 4.5}}}
            }
          },
          %{
            "step" => 1,
            "beliefs" => %{
              "learning_module_0" => %{"graphs" => %{"mug" => %{"max_evidence" => 2.5}}},
              "learning_module_1" => %{"graphs" => %{"mug" => %{"max_evidence" => 5.5}}}
            }
          }
        ]
      }

      assert values(Replay.objects(record)) == [4.5, 5.5]
      assert values(Replay.objects(record, "learning_module_0")) == [1.5, 2.5]
    end

    test "and a module's chart holds only the objects that module held" do
      # A module that ruled bowl out at once has no line for it: the chart is
      # about what that module was still weighing, not about the scene.
      record = %Run{
        timeline: [moment(0)],
        log: [
          %{
            "step" => 0,
            "beliefs" => %{
              "learning_module_0" => %{
                "graphs" => %{
                  "mug" => %{"max_evidence" => 1.0},
                  "bowl" => %{"max_evidence" => 2.0}
                }
              },
              "learning_module_1" => %{"graphs" => %{"mug" => %{"max_evidence" => 3.0}}}
            }
          }
        ]
      }

      assert Enum.map(Replay.objects(record), & &1.label) == ["bowl", "mug"]
      assert Enum.map(Replay.objects(record, "learning_module_1"), & &1.label) == ["mug"]
      assert Replay.objects(record, "learning_module_9") == []
    end

    test "the modules a run reported are named once each, in order" do
      record = %Run{
        timeline: Enum.map([0, 1], &moment/1),
        log: [
          %{
            "step" => 0,
            "beliefs" => %{
              "learning_module_1" => %{"graphs" => %{"mug" => %{"max_evidence" => 1.0}}},
              "learning_module_0" => %{"graphs" => %{"mug" => %{"max_evidence" => 1.0}}}
            }
          },
          %{
            "step" => 1,
            "beliefs" => %{
              "learning_module_1" => %{"graphs" => %{"mug" => %{"max_evidence" => 2.0}}}
            }
          }
        ]
      }

      assert Replay.modules(record) == ["learning_module_0", "learning_module_1"]
      assert Replay.modules(run(0..2)) == []
    end

    test "a run whose modules built no graphs has nothing to draw" do
      assert Replay.objects(run(0..2)) == []
    end

    test "the strongest object of the run is the headline" do
      assert Replay.best_evidence(with_graphs(0..2)) == %{object: "bowl", value: 10.0}
      assert Replay.best_evidence(run(0..2)) == nil
    end

    test "the two theories at a step are the two strongest, the strongest first" do
      # Step 3: the run's guess is still bowl, with mug climbing behind it.
      assert Replay.theories(Replay.at(with_graphs([0, 3]), 3)) == [
               %{object: "bowl", evidence: 7.0},
               %{object: "mug", evidence: 3.0}
             ]
    end

    test "a theory with no evidence behind it is not worth naming" do
      assert Replay.theories(Replay.at(with_graphs([0]), 0)) == [
               %{object: "bowl", evidence: 10.0}
             ]
    end

    test "a step whose modules built no graphs has no theories" do
      assert Replay.theories(Replay.at(run(0..2), 1)) == []
    end

    test "how many theories to name is the caller's choice" do
      assert [%{object: "bowl"}] = Replay.theories(Replay.at(with_graphs([3]), 3), 1)
    end
  end

  describe "a record read without its pictures" do
    # What `RunHistory.head/1` hands a page: the log of every step, and no
    # observations. The observations are a column of their own, fetched for the
    # one step being shown.
    defp log_only(steps), do: %Run{log: Enum.map(steps, &entry/1), timeline: []}

    test "still replays every step it recorded" do
      run = log_only([0, 1, 2])

      assert Replay.steps(run) == [0, 1, 2]
      assert Replay.last_step(run) == 2

      moment = Replay.at(run, 1)
      assert moment.position == 1
      assert moment.step == 1
      assert moment.entry["duration_us"] == 101
      assert moment.frames == []
    end

    test "draws every line the log can draw, and no line it has no observations for" do
      steps = [0, 1, 2]
      drawn = Enum.map(Replay.series(log_only(steps)), & &1.id)
      kept = Enum.map(Replay.series(run(steps)), & &1.id)

      # A sensor line is where the sensor was, which is the observations column;
      # everything the modules concluded is in the log.
      assert drawn == Enum.reject(kept, &String.starts_with?(&1, "sensor:"))
      assert "evidence" in drawn
    end

    test "takes the pictures back one step at a time" do
      run = log_only([0, 1])
      moment = Replay.at(run, 1)

      filled = Replay.with_pictures(moment, %{"patch" => %{"images" => %{"depth" => "png"}}})

      assert [%{sensor_id: "patch"}] = filled.frames
      assert Replay.with_pictures(moment, nil) == moment
      assert Replay.with_pictures(nil, %{}) == nil
    end

    test "says a run kept no pictures when no step has one" do
      refute Replay.kept_pictures?(%{"patch" => %{"location" => [0.0, 0.0, 0.1]}})
      assert Replay.kept_pictures?(%{"patch" => %{"images" => %{"depth" => "png"}}})
      refute Replay.kept_pictures?(nil)
    end
  end
end
