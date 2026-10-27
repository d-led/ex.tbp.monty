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
end
