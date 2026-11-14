defmodule Monty.Studio.PartsTest do
  @moduledoc """
  The cards a page draws for the parts of one press of Run.

  Monty's parallel runner produces one config per part and the pyview dashboard
  draws a section per publisher; a card here is that section — which part it is,
  the stretch it takes, the strongest evidence it holds and the pictures its last
  step took. These cases are about reading those off the records and the live
  stream, not about the drawing's geometry (`chart_test.exs` is that).
  """

  use ExTbpMontyWeb.ConnCase, async: false

  alias Monty.Studio.{Parts, RunHistory}

  @experiment "base_config_10distinctobj_dist_agent"

  # A node that is not this one, as a part's row spells it: the folder name a
  # claim is written with (`ExTbpMonty.Node.safe_name/1`).
  @peer "node2_127.0.0.1"

  setup do
    _root = Monty.Test.Tmp.env_dir("studio-parts", :studio_artifacts_dir)
    {:ok, opened} = Monty.Studio.open(@experiment)
    {:ok, setup: opened.setup}
  end

  describe "the parts of a run" do
    test "one card each, in the order the plan numbered them", %{setup: setup} do
      {record, _parts} = run([[0, 1, 2, 3], [4, 5, 6, 7]])

      cards = record |> Parts.refresh(%{}) |> Parts.cards(setup)

      assert Enum.map(cards, & &1.label) == ["part 1 of 2", "part 2 of 2"]
      assert Enum.map(cards, & &1.span) == ["episodes 0–3", "episodes 4–7"]
    end

    test "a card says the object a part is about, and its stretch of the experiment", %{
      setup: setup
    } do
      # Episode 0 is the first object the config names, episode 1 the second: a
      # part of two episodes is about two objects, and says so by naming neither.
      {record, _parts} = run([[0], [1, 2]])

      [single, several] = record |> Parts.refresh(%{}) |> Parts.cards(setup)

      assert single.object == Enum.at(Monty.Studio.Setup.objects(setup, :eval), 0)
      assert single.span == "episode 0"
      assert several.object == nil
    end

    test "a card's evidence is the strongest it holds, and its chart has that step", %{
      setup: setup
    } do
      {record, _parts} = run([[0, 1], [2, 3]])

      {:ok, _written} =
        RunHistory.checkpoint_steps(
          record,
          [entry(0, 0, 1.0), entry(1, 1, 2.5), entry(0, 0, 9.0, 1)],
          [],
          timeline: :skip
        )

      [card | _second] = record |> Parts.refresh(%{}) |> Parts.cards(setup)

      # The second part's step is not this card's: one part's card is one part's
      # evidence, whichever part took the step with the most in it.
      assert card.best == %{object: "mug", evidence: 2.5}
      assert card.steps == 2
      assert card.episodes_done == 2
      assert [%{graph_id: "mug"} | _rest] = card.chart.series
    end

    test "a step that reported nothing is not a point on the chart", %{setup: setup} do
      {record, _parts} = run([[0], [1]])

      {:ok, _written} =
        RunHistory.checkpoint_steps(
          record,
          [entry(0, 0, 1.0), step_without_beliefs(1)],
          [],
          timeline: :skip
        )

      [card | _second] = record |> Parts.refresh(%{}) |> Parts.cards(setup)

      assert card.steps == 2
      # One point, because the second step changed nothing to report.
      assert card.chart.x_max == 0
    end
  end

  describe "reading a run twice" do
    test "does not read a settled transcript again", %{setup: setup} do
      # The page polls; a poll that re-read four transcripts twice a second would
      # cost more than the run it is watching.
      {record, _parts} = run([[0], [1]])

      {:ok, _written} =
        RunHistory.checkpoint_steps(record, [entry(0, 0, 1.0)], [], timeline: :skip)

      first = Parts.refresh(record, %{})
      second = Parts.refresh(record, first)

      assert [card | _second] = Parts.cards(second, setup)
      assert card.best == %{object: "mug", evidence: 1.0}
      assert Map.get(second, hd(Map.keys(first))) == Map.get(first, hd(Map.keys(first)))
    end

    test "a part that is still stepping is read from the stream, one step at a time", %{
      setup: setup
    } do
      # While a part steps its steps are in `RunStream`, and the record holds only
      # what a part's completion wrote: a card drawn from the record alone would
      # stand still until the part was finished.
      {record, [first | _more]} = run([[0], [1]])
      stream = first["stream"]

      Monty.Studio.RunStream.publish(stream, step(0, 1.0))
      Monty.Studio.RunStream.publish(stream, step(1, 3.0))

      held = Parts.refresh(record, %{})
      assert [card | _second] = Parts.cards(held, setup)
      assert card.best == %{object: "mug", evidence: 3.0}
      assert Map.get(held, stream).taken == 2

      # The next poll reads the new step and nothing else.
      Monty.Studio.RunStream.publish(stream, step(2, 4.0))
      held = Parts.refresh(record, held)

      assert [card | _second] = Parts.cards(held, setup)
      assert card.best == %{object: "mug", evidence: 4.0}
      assert Map.get(held, stream).taken == 3
    end
  end

  # A page opened while a peer steps a part: that part's steps are in the peer's
  # memory, and this node's stream knows nothing about them. Before this, such a
  # page stood still until the part ended and its file was written.
  describe "a part a peer is stepping" do
    test "reads the steps it took before the page opened from the node that has it", %{
      setup: setup
    } do
      {record, parts} = run([[0], [1]])
      in_a_peers_hands(record, parts, 0)

      held =
        Parts.refresh(record, %{},
          read: fn node, stream, from ->
            assert node == @peer
            assert stream == hd(parts)["stream"]
            assert from == -1, "a page that has read nothing asks from nought"
            [entry(0, 0, 1.0), entry(0, 1, 4.0)]
          end
        )

      assert [card | _second] = Parts.cards(held, setup)
      assert card.steps == 2
      assert card.best == %{object: "mug", evidence: 4.0}
    end

    test "asks for what it has not read yet, not the whole part again", %{setup: setup} do
      {record, parts} = run([[0], [1]])
      in_a_peers_hands(record, parts, 0)

      answer = fn node, _stream, from ->
        send(self(), {:asked, node, from})
        if from < 0, do: [entry(0, 0, 1.0)], else: [entry(0, 1, 2.0)]
      end

      held = Parts.refresh(record, %{}, read: answer)
      assert_received {:asked, @peer, -1}

      held = Parts.refresh(record, held, read: answer)
      assert_received {:asked, @peer, 0}

      assert [card | _second] = Parts.cards(held, setup)
      assert card.steps == 2
    end

    test "a peer that does not answer leaves the card on the record's transcript", %{
      setup: setup
    } do
      {record, parts} = run([[0], [1]])
      in_a_peers_hands(record, parts, 0)

      {:ok, _written} =
        RunHistory.checkpoint_steps(record, [entry(0, 0, 2.5)], [], timeline: :skip)

      held = Parts.refresh(record, %{}, read: fn _node, _stream, _from -> [] end)

      assert [card | _second] = Parts.cards(held, setup)
      assert card.best == %{object: "mug", evidence: 2.5}
    end

    test "a part this node is stepping is read here, not asked of anybody", %{setup: setup} do
      {record, parts} = run([[0], [1]])
      in_a_peers_hands(record, parts, 0, ExTbpMonty.Node.safe_name(node()))

      Monty.Studio.RunStream.publish(hd(parts)["stream"], step(0, 3.0))

      held =
        Parts.refresh(record, %{},
          read: fn _node, _stream, _from ->
            flunk("a part in this node's own hands was asked of a peer")
          end
        )

      assert [card | _second] = Parts.cards(held, setup)
      assert card.best == %{object: "mug", evidence: 3.0}
    end
  end

  # One run asked for two or more parts, as the page records it: the plan is in
  # the record's inputs, and each part's steps are the stream the plan names.
  defp run(episodes_per_part) do
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

    {:ok, record} =
      RunHistory.start(%{
        experiment: @experiment,
        source: "monty",
        steps: 2,
        episode: 0,
        inputs: %{"parallel" => length(parts), "parts" => parts}
      })

    {record, parts}
  end

  # A part in a node's hands, as a divided run's row says it: planned by the
  # worker, then claimed by the node that steps it.
  defp in_a_peers_hands(record, parts, index, node \\ @peer) do
    :ok =
      RunHistory.plan_parts(
        record.id,
        Enum.map(parts, &%{index: &1["index"], of: &1["of"]})
      )

    {:ok, _claim} = RunHistory.claim_part(record.id, index, node)
    :ok
  end

  # What a step's transcript entry is: the episode of the run, the step, the part
  # that took it, and what the module believed.
  defp entry(episode, step, evidence, part \\ 0) do
    %{
      "episode" => episode,
      "step" => step,
      "part" => part,
      "at" => Monty.Studio.RunLog.now().instant,
      "beliefs" => %{
        "learning_module_0" => %{
          "graphs" => %{
            "mug" => %{"max_evidence" => evidence, "hypotheses" => 4, "within_x_percent" => 2}
          },
          "possible_matches" => ["mug"]
        }
      }
    }
  end

  defp step_without_beliefs(step) do
    %{"episode" => 0, "step" => step, "part" => 0, "at" => Monty.Studio.RunLog.now().instant}
  end

  # A step as a live run hands it over: the report `RunStream.publish/2` turns
  # into the entry a card reads.
  defp step(number, evidence) do
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
      episode: 0,
      beliefs: %{
        learning_module_0:
          Monty.Studio.Belief.from_stored(
            entry(0, number, evidence)["beliefs"]["learning_module_0"]
          )
      },
      observations: %{},
      sensor_ids: [],
      centre: nil
    }
  end
end
