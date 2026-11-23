defmodule Monty.Studio.SummaryTest do
  use ExUnit.Case, async: true

  alias Monty.Studio.{Setup, Summary}

  defp step(overrides \\ %{}) do
    Map.merge(
      %{
        step: 0,
        percept_ids: [:patch],
        inputs: %{"learning_module_0" => 1},
        votes: %{sent: 1, used: 1, deadline_hit?: false},
        goals: 1,
        actions: [%{"action" => "move_forward"}],
        sensor_timeouts: [],
        duration_us: 1_000
      },
      overrides
    )
  end

  test "a run of three steps is three steps, with the votes and goals added up" do
    summary = Summary.from_infos([step(), step(), step()])

    assert summary.steps == 3
    assert summary.votes_sent == 3
    assert summary.votes_used == 3
    assert summary.goals == 3
    assert summary.actions == 3
    assert summary.duration_us == 3_000
  end

  # A step's own clock measures the modules, not the world that moved the agent
  # before them. Reporting only the model's time made 772 s of a run read as the
  # studio's, so both halves are kept and the wall clock is the row's.
  test "the world's time is kept beside the model's, and the two are what compute is" do
    summary =
      Summary.from_infos([
        step(%{duration_us: 900, world_us: 300}),
        step(%{duration_us: 1_100, world_us: 200})
      ])

    assert summary.duration_us == 2_000
    assert summary.world_us == 500
    assert Summary.compute_us(summary) == 2_500
  end

  test "a step from a world that times nothing is a step with no world time" do
    assert Summary.from_infos([step()]).world_us == 0
  end

  test "a step that hit the vote deadline is counted, because a late vote is a different run" do
    summary =
      Summary.from_infos([step(), step(%{votes: %{sent: 1, used: 0, deadline_hit?: true}})])

    assert summary.deadline_hits == 1
    assert summary.votes_used == 1
  end

  test "inputs are per module, so one silent module cannot hide behind another" do
    summary =
      Summary.from_infos([
        step(%{inputs: %{"learning_module_0" => 1, "learning_module_1" => 0}}),
        step(%{inputs: %{"learning_module_0" => 1}})
      ])

    assert summary.inputs == %{"learning_module_0" => 2, "learning_module_1" => 0}
  end

  test "a learning module that never received input is named" do
    {:ok, setup} = Setup.from_experiment("randrot_noise_10distinctobj_5lms_dist_agent")

    summary =
      Summary.from_infos([step(%{inputs: %{"learning_module_0" => 1}})], setup)

    assert length(summary.never_updated) == 4
    assert "learning_module_0" not in summary.never_updated
  end

  test "a run with no steps has no average rather than a division by zero" do
    assert Summary.average_step_us(Summary.from_infos([])) == nil

    assert Summary.average_step_us(Summary.from_infos([step(), step()])) == 1_000.0
  end

  test "sensor timeouts are listed once each" do
    summary =
      Summary.from_infos([step(%{sensor_timeouts: [:patch]}), step(%{sensor_timeouts: [:patch]})])

    assert summary.sensor_timeouts == [:patch]
  end

  describe "what a page reads out of a stored summary" do
    test "each amount is named, and a time is in the unit that reads" do
      rows =
        Summary.rows(%{
          "steps" => 40,
          "duration_us" => 1_491_954,
          "world_us" => 374_557,
          "goals" => 61_215,
          "actions" => 80,
          "votes_sent" => 40,
          "votes_used" => 40,
          "deadline_hits" => 0,
          "inputs" => %{"learning_module_0" => 40},
          "outcome" => %{"learning_module_0" => nil},
          "outcomes" => %{"learning_module_0" => %{"match" => 2, "time_out" => 1}}
        })

      assert {"steps", "40"} in rows
      assert {"took", "1.49 s"} in rows
      assert {"world took", "374.6 ms"} in rows
      assert {"deadline misses", "none"} in rows
      assert {"module steps", "learning_module_0=40"} in rows
      assert {"last step", "learning_module_0: no conclusion"} in rows
      assert {"episodes concluded", "learning_module_0: match 2, time_out 1 of 3"} in rows
    end

    test "the counts come in the order a reader asks them in" do
      labels =
        Summary.rows(%{"goals" => 1, "steps" => 2, "actions" => 3})
        |> Enum.map(&elem(&1, 0))

      assert labels == ["steps", "actions", "goals"]
    end

    test "a key this build does not know is still words" do
      assert [{"some new thing", "7"}] = Summary.rows(%{"some_new_thing" => 7})
    end

    test "a summary with nothing in it says nothing" do
      assert Summary.rows(%{}) == []
      assert Summary.rows(%{"reason" => "killed", "technical" => "trace"}) == []
      assert Summary.rows(%{"outcomes" => %{}, "never_updated" => []}) == []
    end
  end
end
