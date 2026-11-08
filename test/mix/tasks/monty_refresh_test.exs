defmodule Mix.Tasks.Monty.RefreshTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Monty.Refresh

  # The order is the whole point: the copy feeds the census, and the map must be
  # rewritten after the checkout moved but before anything claims it did not.
  test "the copy comes first, then what is generated from it, then the checks" do
    assert Enum.map(Refresh.steps(), &elem(&1, 0)) == ~w(
             monty.inputs
             monty.module_map.gen
             monty.target_census
             monty.config.snapshots
             monty.module_map.verify
             monty.readiness
           )
  end

  test "every step is a task that exists" do
    for {task, _arguments} <- Refresh.steps() do
      assert Mix.Task.get(task), "refresh names #{task}, which is not a task"
    end
  end

  # A checkout named once has to reach both halves, or the map would be read from
  # one tree and the copy written from another.
  test "a checkout passed in reaches every step that reads one" do
    steps = Map.new(Refresh.steps(source: "../monty-orig"))

    for task <-
          ~w(monty.inputs monty.module_map.gen monty.config.snapshots monty.module_map.verify) do
      assert steps[task] == ["--source", "../monty-orig"],
             "#{task} did not hear about the checkout"
    end
  end

  test "--no-update reaches the copy and nothing else" do
    steps = Map.new(Refresh.steps(update: false))

    assert steps["monty.inputs"] == ["--no-update"]
    assert steps["monty.config.snapshots"] == []
  end
end
