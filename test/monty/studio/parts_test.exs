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

  setup do
    _root = Monty.Test.Tmp.env_dir("studio-parts", :studio_artifacts_dir)
    {:ok, opened} = Monty.Studio.open(@experiment)
    {:ok, setup: opened.setup}
  end

  describe "the parts of a batch" do
    test "one card each, in the order the plan numbered them", %{setup: setup} do
      batch = Ecto.UUID.generate()

      for index <- 0..1 do
        part(batch, index, 2, Enum.to_list(index..(index + 3)))
      end

      cards = batch |> Parts.refresh(%{}) |> Parts.cards(setup)

      assert Enum.map(cards, & &1.label) == ["part 1 of 2", "part 2 of 2"]
      assert Enum.map(cards, & &1.span) == ["episodes 0–3", "episodes 1–4"]
    end

    test "a card says the object a part is about, and its stretch of the experiment", %{
      setup: setup
    } do
      # Episode 0 is the first object the config names, episode 1 the second: a
      # part of two episodes is about two objects, and says so by naming neither.
      batch = Ecto.UUID.generate()
      part(batch, 0, 1, [0])
      part(batch, 1, 1, [1, 2])

      [single, several] = batch |> Parts.refresh(%{}) |> Parts.cards(setup)

      assert single.object == Enum.at(Monty.Studio.Setup.objects(setup, :eval), 0)
      assert single.span == "episode 0"
      assert several.object == nil
    end

    test "a card's evidence is the strongest it holds, and its chart has that step", %{
      setup: setup
    } do
      batch = Ecto.UUID.generate()
      kept = part(batch, 0, 1, [0, 1])

      {:ok, _written} =
        RunHistory.checkpoint_steps(kept, [entry(0, 0, 1.0), entry(1, 0, 2.5)], [],
          timeline: :skip
        )

      [card] = batch |> Parts.refresh(%{}) |> Parts.cards(setup)

      assert card.best == %{object: "mug", evidence: 2.5}
      assert card.steps == 2
      assert card.episodes_done == 2
      assert [%{graph_id: "mug"} | _rest] = card.chart.series
    end

    test "a step that reported nothing is not a point on the chart", %{setup: setup} do
      batch = Ecto.UUID.generate()
      kept = part(batch, 0, 1, [0])

      {:ok, _written} =
        RunHistory.checkpoint_steps(kept, [entry(0, 0, 1.0), step_without_beliefs(1)], [],
          timeline: :skip
        )

      [card] = batch |> Parts.refresh(%{}) |> Parts.cards(setup)

      assert card.steps == 2
      # One point, because the second step changed nothing to report.
      assert card.chart.x_max == 0
    end
  end

  describe "reading a batch twice" do
    test "does not read a settled record's transcript again", %{setup: setup} do
      # The page polls; a poll that re-read four transcripts twice a second would
      # cost more than the run it is watching.
      batch = Ecto.UUID.generate()
      kept = part(batch, 0, 1, [0])

      {:ok, _written} = RunHistory.checkpoint_steps(kept, [entry(0, 0, 1.0)], [], timeline: :skip)

      first = Parts.refresh(batch, %{})
      second = Parts.refresh(batch, first)

      assert [card] = Parts.cards(second, setup)
      assert card.best == %{object: "mug", evidence: 1.0}
      assert Map.get(second, kept.id) == Map.get(first, kept.id)
    end

    test "a part that is still stepping is read from the stream, one step at a time", %{
      setup: setup
    } do
      # While a part runs its steps are in `RunStream`, and its record holds only
      # what a boundary wrote: a card drawn from the record alone would stand
      # still between boundaries.
      batch = Ecto.UUID.generate()
      kept = part(batch, 0, 1, [0])

      Monty.Studio.RunStream.publish(kept.id, step(0, 1.0))
      Monty.Studio.RunStream.publish(kept.id, step(1, 3.0))

      held = Parts.refresh(batch, %{})
      first = Parts.cards(held, setup)
      assert [card] = first
      assert card.best == %{object: "mug", evidence: 3.0}
      assert Map.get(held, kept.id).taken == 2

      # The next poll reads the new step and nothing else.
      Monty.Studio.RunStream.publish(kept.id, step(2, 4.0))
      held = Parts.refresh(batch, held)

      assert [card] = Parts.cards(held, setup)
      assert card.best == %{object: "mug", evidence: 4.0}
      assert Map.get(held, kept.id).taken == 3
    end
  end

  # A part's record, as the page queues one (Monty.Studio.Partition).
  defp part(batch, index, of, episodes) do
    {:ok, record} =
      RunHistory.start(%{
        experiment: @experiment,
        source: "monty",
        steps: 2,
        episode: hd(episodes),
        inputs: %{
          "batch" => batch,
          "part" => %{
            "index" => index,
            "of" => of,
            "phases" => %{"eval" => episodes}
          }
        }
      })

    record
  end

  # What a step's transcript entry is: the episode of the run, the step, and what
  # the module believed.
  defp entry(episode, step, evidence) do
    %{
      "episode" => episode,
      "step" => step,
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
    %{"episode" => 0, "step" => step, "at" => Monty.Studio.RunLog.now().instant}
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
