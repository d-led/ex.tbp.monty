defmodule Monty.Studio.CatchUpTest do
  @moduledoc """
  What a page has missed, asked of the streams a run is writing.

  A run of one part writes one stream and this is a tail read of it. A divided run
  writes one per part, some of them on other nodes, and that is the case these
  cases are about: the run's own stream says nothing, so the parts answer — here
  when this node holds them, and over the network when a peer does.
  """

  use ExTbpMontyWeb.ConnCase, async: false

  alias Monty.Studio.{CatchUp, RunHistory, RunStream}

  @experiment "base_config_10distinctobj_dist_agent"
  @peer "node2_127.0.0.1"

  setup do
    _root = Monty.Test.Tmp.env_dir("studio-catch-up", :studio_artifacts_dir)
    :ok
  end

  describe "a run of one part" do
    test "reads the run's own stream from the step the page stopped at" do
      record = run([])
      RunStream.publish(record.id, step(0))
      RunStream.publish(record.id, step(1))

      {entries, cursors} = CatchUp.entries(record, %{})

      assert Enum.map(entries, & &1["step"]) == [0, 1]
      assert Map.get(cursors, record.id) == 2

      # The next poll has nothing to read, and says so without reading.
      assert {[], next} = CatchUp.entries(record, cursors)
      assert Map.get(next, record.id) == 2
    end
  end

  describe "a divided run" do
    test "reads every part's stream this node holds, oldest step first" do
      {record, [first, second]} = run_with_parts([[0], [1]])

      RunStream.publish(first["stream"], step(3, 0))
      RunStream.publish(second["stream"], step(0, 1))

      {entries, cursors} = CatchUp.entries(record, %{})

      # Two parts, two streams, and the order is the run's: episode first.
      assert Enum.map(entries, &{&1["episode"], &1["step"]}) == [{0, 3}, {1, 0}]
      assert Map.get(cursors, first["stream"]) == 1
      assert Map.get(cursors, second["stream"]) == 1
    end

    test "a part in a peer's hands is asked of the node that has it" do
      {record, [first, _second]} = run_with_parts([[0], [1]])

      claimed = %{first["index"] => %{node: @peer, steps: 2}}

      read = fn holder, stream, from ->
        send(self(), {:asked, holder, stream, from})
        if from < 0, do: [entry(0), entry(1)], else: [entry(0)]
      end

      {entries, cursors} = CatchUp.entries(record, %{}, claimed: claimed, read: read)

      assert_received {:asked, @peer, stream, -1}
      assert stream == first["stream"]
      assert Enum.map(entries, & &1["step"]) == [0, 1]
      assert Map.get(cursors, first["stream"]) == 2

      # The claim says two steps and the page has drawn two: the peer is not asked
      # again, which is the whole reason the claim row carries a count.
      assert {[], _cursors} = CatchUp.entries(record, cursors, claimed: claimed, read: read)
      refute_received {:asked, @peer, _stream, _from}
    end

    test "a peer that answers nothing leaves the page on the record" do
      {record, [first, _second]} = run_with_parts([[0], [1]])

      claimed = %{first["index"] => %{node: @peer, steps: 4}}

      assert {[], _cursors} =
               CatchUp.entries(record, %{}, claimed: claimed, read: fn _, _, _ -> [] end)
    end
  end

  describe "how much a page can count on its own" do
    test "is this node's streams plus what the claims say of the parts a peer has" do
      {record, [first, second]} = run_with_parts([[0], [1]])

      RunStream.publish(first["stream"], step(0, 0))
      RunStream.publish(first["stream"], step(1, 0))

      claimed = %{second["index"] => %{node: @peer, steps: 5}}

      assert CatchUp.held(record, claimed: claimed) == 2 + 5
    end
  end

  defp run_with_parts(episodes_per_part) do
    parts =
      episodes_per_part
      |> Enum.with_index()
      |> Enum.map(fn {episodes, index} ->
        %{
          "index" => index,
          "of" => length(episodes_per_part),
          "phase" => "eval",
          "stream" => Ecto.UUID.generate(),
          "phases" => %{"eval" => episodes}
        }
      end)

    {run_with(parts), parts}
  end

  defp run([]), do: run_with([])

  defp run_with(parts) do
    {:ok, record} =
      RunHistory.start(%{
        experiment: @experiment,
        source: "monty",
        steps: 5,
        episode: 0,
        inputs: %{"parallel" => max(length(parts), 1), "parts" => parts}
      })

    record
  end

  # A step as a live run hands it over: the report `RunStream.publish/2` turns into
  # the entry a page reads.
  defp step(number, episode \\ 0) do
    %{
      info: %{
        step: number,
        percept_ids: [],
        inputs: %{},
        votes: %{sent: 0, used: 0},
        goals: 0,
        actions: [],
        duration_us: 1
      },
      at: Monty.Studio.RunLog.now().instant,
      episode: episode,
      beliefs: %{},
      observations: %{},
      sensor_ids: [],
      centre: nil
    }
  end

  # A transcript entry, which is what a peer's read answers: the run's episode and
  # the step number inside it, which is the pair a page orders by.
  defp entry(step, episode \\ 0), do: %{"episode" => episode, "step" => step}
end
