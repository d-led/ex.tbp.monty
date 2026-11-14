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

  test "gives back the heap a big batch grew, once there is nothing to do", %{run: run} do
    # The writer keeps no state: what it holds is what it is working on. Its heap
    # is the shape of the largest batch handed over, and nothing in the runtime
    # shrinks an idle process's heap — on a live run this one sat on 331 MB with
    # an empty mailbox, a third of the node's memory, and the machine crossed its
    # memory watermark every ten minutes.
    :ok = RunWriter.checkpoint(run, {big_batch(200), [moment(0)]}, 200)
    _ = :sys.get_state(RunWriter)

    # A megabyte of batch cannot leave a heap this small behind: the writer has
    # given the batch's heap back rather than holding it until the node stops.
    assert eventually(fn -> heap_words(RunWriter) < 10_000 end)
  end

  defp big_batch(count) do
    for step <- 1..count, do: Map.put(entry(step), "pad", String.duplicate("x", 5_000))
  end

  defp heap_words(name) do
    case Process.info(Process.whereis(name), :total_heap_size) do
      {:total_heap_size, words} -> words
      nil -> :infinity
    end
  end

  # The waiting is the thing being asserted, so it is observed rather than
  # guessed at: poll, and stop the moment the writer has let go.
  defp eventually(condition, tries \\ 100) do
    cond do
      condition.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(condition, tries - 1)
    end
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
