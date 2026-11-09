defmodule Monty.Studio.RunWriterTest do
  @moduledoc """
  The writer keeps the run's promise that its record is the run's transcript.

  A boundary hands the steps over instead of writing them itself, so what has to
  hold is that the hand-over lands — in the order it was made — and that the
  closing write comes after everything already handed over.
  """

  use ExTbpMontyWeb.ConnCase

  alias Monty.Studio.RunHistory
  alias Monty.Studio.RunWriter

  setup do
    ExTbpMonty.Repo.delete_all(RunHistory.Run)

    {:ok, run} =
      RunHistory.start(%{
        experiment: "tutorial/first_experiment",
        source: "monty",
        steps: 0,
        config: %{}
      })

    {:ok, run: run}
  end

  test "the steps an episode hands over are in the record when it is asked", %{run: run} do
    :ok = RunWriter.checkpoint(run, {[entry(0)], [moment(0)]}, 1)
    :ok = RunWriter.checkpoint(run, {[entry(1)], [moment(1)]}, 2)

    # The writes are the writer's to make; asking it for its state waits for the
    # casts it already has (`AGENTS.md`: no sleeping in tests).
    _ = :sys.get_state(RunWriter)

    assert steps_in_the_record(run.id) == [0, 1]
  end

  test "the closing write carries everything, and comes after what was handed over", %{run: run} do
    :ok = RunWriter.checkpoint(run, {[entry(0)], [moment(0)]}, 1)

    assert {:ok, saved} = RunWriter.store(run, [entry(0), entry(1)], [moment(0), moment(1)])

    assert saved.steps_done == 2
    assert steps_in_the_record(run.id) == [0, 1]
  end

  defp entry(step), do: %{"step" => step, "duration_us" => 100}
  defp moment(step), do: %{"step" => step, "at" => "2026-11-09T00:00:0#{step}.000000Z"}

  defp steps_in_the_record(id) do
    id
    |> RunHistory.get()
    |> Map.fetch!(:log)
    |> Enum.map(& &1["step"])
  end
end
