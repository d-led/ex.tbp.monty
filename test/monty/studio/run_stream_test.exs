defmodule Monty.Studio.RunStreamTest do
  @moduledoc """
  What a step hands over, and what becomes of it.

  A worker's step publishes a *report* — what the coordinator reported, what each
  module believed, what the sensors saw, and the moment it happened — and this
  process makes the record's entry, the log's line and the page's announcement
  out of it. These tests pin that division: a report is enough, and the moment
  that travels with it is the moment the step was taken, not the moment it was
  written.
  """

  use ExUnit.Case, async: true

  alias Monty.Studio.{Artifacts, RunLog, RunStream}

  # A moment far enough from now that a line carrying it cannot be mistaken for
  # one carrying the clock of the process that wrote it.
  @moment "2026-11-09T22:41:27.137962Z"

  setup do
    run_id = Ecto.UUID.generate()
    :ok = Artifacts.start(run_id)
    on_exit(fn -> Artifacts.forget(run_id) end)

    %{run_id: run_id}
  end

  describe "a step's report" do
    test "becomes a step of the record, with the moment it was taken", %{run_id: run_id} do
      beliefs = %{"learning_module_0" => %{"graphs" => %{"mug" => %{"max_evidence" => 5.0}}}}

      RunStream.publish(
        run_id,
        report(step: 7, episode: 3, beliefs: beliefs, at: @moment)
      )

      assert {[entry], [_moment]} = RunStream.steps(run_id)

      assert entry["step"] == 7
      assert entry["episode"] == 3
      assert entry["at"] == @moment
      assert entry["beliefs"]["learning_module_0"]["graphs"]["mug"]["max_evidence"] == 5.0
    end

    test "is enough for the line the log and the page are given", %{run_id: run_id} do
      Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Monty.Studio.Jobs.Run.topic(run_id))

      RunStream.publish(run_id, report(step: 7, at: @moment))

      # Five seconds, not the default tenth of one: the announcement comes from
      # the stream's own process, and a suite running sixteen cases at a time can
      # keep that process waiting. The wait is the answer arriving, not a sleep.
      assert_receive {:studio, ^run_id, {:step, announcement}}, 5_000

      clock = RunLog.at(%{"at" => @moment}).clock

      assert announcement.step == 7
      assert String.starts_with?(announcement.line, clock)
      assert announcement.line =~ "step 7"
    end

    test "writes the line to the run's own log file", %{run_id: run_id} do
      Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Monty.Studio.Jobs.Run.topic(run_id))

      RunStream.publish(run_id, report(step: 1, at: @moment))

      # The broadcast follows the write, so a step the page has heard of is a
      # step the file has too.
      assert_receive {:studio, ^run_id, {:step, _announcement}}, 5_000

      assert File.read!(Artifacts.log_path(run_id)) =~ "step 1"
    end
  end

  # What a page reads, and what a boundary writes, both come from this table:
  # `steps_from/2` asks the process only for the order and then reads here, and
  # `read_from/2` is that read. The keys are ordinary table keys, so the mistake
  # that is easy to make and invisible until two runs are open at once is reading
  # on past the end of one run and into the next.
  describe "the steps a page reads" do
    test "are the ones after the position it already has", %{run_id: run_id} do
      for step <- 1..4, do: RunStream.publish(run_id, report(step: step))
      settled(run_id)

      {entries, moments} = RunStream.read_from(run_id, 1)

      assert Enum.map(entries, & &1["step"]) == [3, 4]
      assert length(moments) == 2
    end

    test "stop at the end of the run they belong to", %{run_id: run_id} do
      other = Ecto.UUID.generate()
      :ok = Artifacts.start(other)
      on_exit(fn -> Artifacts.forget(other) end)

      RunStream.publish(run_id, report(step: 1))
      RunStream.publish(other, report(step: 1))
      RunStream.publish(run_id, report(step: 2))
      settled(run_id)

      {entries, _moments} = RunStream.read_from(run_id, -1)

      assert Enum.map(entries, & &1["step"]) == [1, 2]
    end

    test "are read whole when the page asks for everything", %{run_id: run_id} do
      for step <- 1..3, do: RunStream.publish(run_id, report(step: step))
      settled(run_id)

      assert {entries, moments} = RunStream.steps_from(run_id, -1)
      assert Enum.map(entries, & &1["step"]) == [1, 2, 3]
      assert length(moments) == 3
    end

    test "are none, for a run this node never stepped", %{run_id: run_id} do
      settled(run_id)

      assert RunStream.read_from(Ecto.UUID.generate(), -1) == {[], []}
    end

    test "are none once the run's record holds them", %{run_id: run_id} do
      RunStream.publish(run_id, report(step: 1))
      settled(run_id)

      :ok = RunStream.clear(run_id)

      assert RunStream.read_from(run_id, -1) == {[], []}
      assert RunStream.count(run_id) == 0
    end
  end

  # Everything the test process has handed over, so far, has landed: a call
  # answers after the casts that came before it.
  defp settled(run_id), do: RunStream.count(run_id)

  # A step, the way a worker hands one over: what it reported, what the modules
  # believed, what the sensors saw, and when.
  defp report(options) do
    %{
      info: %{
        step: Keyword.fetch!(options, :step),
        percept_ids: [:patch],
        inputs: %{learning_module_0: 1},
        votes: %{sent: 1, used: 1},
        goals: 0,
        actions: [:turn_left],
        duration_us: 140
      },
      at: Keyword.get(options, :at, @moment),
      episode: Keyword.get(options, :episode, 0),
      beliefs: Keyword.get(options, :beliefs, %{}),
      observations: %{},
      sensor_ids: [],
      centre: nil
    }
  end
end
