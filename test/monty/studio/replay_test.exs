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
      moment = Replay.at(run(0..3), 2)

      assert moment.step == 2
      assert moment.frames |> Enum.map(& &1.sensor_id) |> Enum.sort() == ["patch", "view_finder"]

      # The camera draws the recorded location, so the frame is history. A
      # recorded step keeps the percept, not the pixels — the camera arrays are
      # dropped on the way into the database, because they are four thousand
      # numbers a step — so the frame says there is no picture rather than
      # drawing one that the run never had.
      assert moment.frames |> Enum.find(&(&1.sensor_id == "patch")) |> Map.get(:note) =~
               "no image"
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
               %{step: 0, value: 0.0},
               %{step: 1, value: 0.01},
               %{step: 2, value: 0.02}
             ]
    end

    test "continue with what the modules made of it" do
      assert Replay.chart_series(run(0..1), "percepts").points == [
               %{step: 0, value: 1},
               %{step: 1, value: 1}
             ]

      assert Replay.chart_series(run(0..1), "votes_used").points == [
               %{step: 0, value: 1},
               %{step: 1, value: 0}
             ]

      assert Replay.chart_series(run(0..1), "duration_us").unit == "µs"
    end

    test "have a point for every step, even when the log is missing one" do
      run = %Run{timeline: [moment(0), moment(1)], log: [entry(0)]}

      assert Replay.chart_series(run, "percepts").points == [
               %{step: 0, value: 1},
               %{step: 1, value: 0}
             ]
    end

    test "show the evidence the run climbed to, which is how an episode is judged" do
      run = %Run{
        timeline: [moment(0), moment(1), moment(2)],
        log: [believe(entry(0), 0.5), believe(entry(1), 4.0), believe(entry(2), 9.5)]
      }

      assert %{label: "best evidence", unit: ""} = Replay.chart_series(run, "evidence")

      assert Replay.chart_series(run, "evidence").points == [
               %{step: 0, value: 0.5},
               %{step: 1, value: 4.0},
               %{step: 2, value: 9.5}
             ]
    end

    test "take the best evidence across the modules that reported" do
      run = %Run{
        timeline: [moment(0)],
        log: [believe(entry(0), %{"learning_module_0" => 1.0, "learning_module_1" => 7.0})]
      }

      assert Replay.chart_series(run, "evidence").points == [%{step: 0, value: 7.0}]
    end

    test "say a run believed nothing when no module believed anything" do
      assert Replay.chart_series(run(0..1), "evidence").points == [
               %{step: 0, value: 0.0},
               %{step: 1, value: 0.0}
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

      assert Replay.chart_series(run, "sensor:patch").points == [%{step: 0, value: 0.5}]
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
      assert Replay.zoom(run([7]), {7, 7}, 7, :in) == {7, 7}
      assert Replay.zoom(run([7]), {7, 7}, 7, :out) == {7, 7}
    end
  end
end
