defmodule Monty.Studio.IndexTest do
  use ExUnit.Case, async: true

  alias Monty.Studio.Index

  # A fixture, so the behaviour under test is the filtering and not Monty's
  # current file list.
  defp experiment(name, environment, learning_module, connectivity, config \\ %{}) do
    %{
      name: name,
      experiment_class: "tbp.monty.frameworks.experiments.monty_experiment.MontyExperiment",
      groups: %{
        "environment" => environment,
        "monty/learning_module" => learning_module,
        "monty/connectivity" => connectivity
      },
      config: config
    }
  end

  # An experiment a plugin defines: no groups, no config here — only the node that
  # brings it (`Monty.Studio.Catalog.plugin_experiments/0`).
  defp plugin(name, host), do: %{name: name, host: host, node: :"#{host}@127.0.0.1"}

  describe "an experiment a plugin brings" do
    test "is listed with the ones this node has, and says which node brings it" do
      index =
        Index.build([
          experiment("ours", "habitat_ycb_dist_agent", "evidence_1lm", "1lm_1sm"),
          plugin("theirs", "node2_127.0.0.1")
        ])

      assert [%{name: "ours", host: nil}, %{name: "theirs", host: "node2_127.0.0.1"}] =
               index.entries
    end

    # What a config would have said is not knowable here: the plugin defines it, so
    # the row says unknown rather than guessing "scratch" or "0 lm".
    test "says unknown about everything it would have to read a config for" do
      index = Index.build([plugin("theirs", "node2_127.0.0.1")])

      assert [entry] = index.entries

      assert {entry.agent, entry.modules, entry.learning_module, entry.model} ==
               {"unknown", "unknown", "unknown", "unknown"}

      assert {entry.ready, entry.world} == {"unknown", "unknown"}
    end

    test "can be found by typing the node that brings it" do
      index =
        Index.build([
          experiment("ours", "habitat_ycb_dist_agent", "evidence_1lm", "1lm_1sm"),
          plugin("theirs", "node2_127.0.0.1")
        ])

      assert [%{name: "theirs"}] = Index.filter(index, %{"q" => "node2"}).entries
    end

    test "can be filtered to the nodes that bring something, and only those" do
      index =
        Index.build([
          experiment("ours", "habitat_ycb_dist_agent", "evidence_1lm", "1lm_1sm"),
          plugin("one", "node2_127.0.0.1"),
          plugin("two", "node2_127.0.0.1"),
          plugin("three", "node3_127.0.0.1")
        ])

      assert %{values: values} = Enum.find(index.facets, &(&1.key == "host"))

      assert values == [
               %{value: "node2_127.0.0.1", label: "node2_127.0.0.1", count: 2},
               %{value: "node3_127.0.0.1", label: "node3_127.0.0.1", count: 1}
             ]

      assert index
             |> Index.filter(%{"host" => ["node2_127.0.0.1"]})
             |> Map.get(:entries)
             |> Enum.map(& &1.name) ==
               ["one", "two"]
    end
  end

  defp index do
    Index.build([
      experiment(
        "dist_1lm",
        "habitat_ycb_dist_agent_semantics0",
        "evidence_1lm_nn5_dod003",
        "1lm_1sm"
      ),
      experiment(
        "surf_5lm",
        "habitat_ycb_surf_agent_semantics0",
        "evidence_5lm_nn10_dod003",
        "5lm_5sm",
        %{
          "model_name_or_path" => "/models/surf"
        }
      ),
      experiment(
        "surf_1lm_scratch",
        "habitat_ycb_surf_agent_semantics0",
        "displacement_1lm",
        "1lm_1sm"
      )
    ])
  end

  describe "what an experiment is labelled with" do
    test "the agent comes from the environment it drives" do
      entry = index().entries |> Enum.find(&(&1.name == "surf_5lm"))

      assert entry.agent == "surf"
    end

    test "the module count comes from the learning module or the wiring" do
      entry = index().entries |> Enum.find(&(&1.name == "surf_5lm"))

      assert entry.modules == 5
    end

    test "starting from a trained model is not the same as training from scratch" do
      trained = index().entries |> Enum.find(&(&1.name == "surf_5lm"))
      scratch = index().entries |> Enum.find(&(&1.name == "surf_1lm_scratch"))

      assert trained.model == "pretrained"
      assert scratch.model == "scratch"
    end
  end

  describe "narrowing the list" do
    test "a facet keeps the experiments that have that value" do
      result = Index.filter(index(), %{"agent" => "surf"})

      assert Enum.map(result.entries, & &1.name) == ["surf_1lm_scratch", "surf_5lm"]
    end

    test "two values in one facet are alternatives" do
      result = Index.filter(index(), %{"agent" => "surf,dist"})

      assert result.matching == 3
    end

    test "two facets have to hold at the same time" do
      result = Index.filter(index(), %{"agent" => "surf", "modules" => "5"})

      assert Enum.map(result.entries, & &1.name) == ["surf_5lm"]
    end

    test "the search box matches the name or a component it uses" do
      assert Index.filter(index(), %{"q" => "surf_5lm"}).matching == 1
      assert Index.filter(index(), %{"q" => "displacement"}).matching == 1
      assert Index.filter(index(), %{"q" => "nothing-like-this"}).matching == 0
    end

    test "every word has to match" do
      assert Index.filter(index(), %{"q" => "surf 5lm"}).matching == 1
      assert Index.filter(index(), %{"q" => "surf 5lm 1sm"}).matching == 0
    end

    test "with nothing asked for, everything is shown and nothing is filtered" do
      result = Index.filter(index(), %{})

      assert result.matching == 3
      refute result.filtered?
    end
  end

  describe "the counts next to the pills" do
    test "a facet counts under the other filters, not under all of them" do
      # Two surface experiments; of them, one has five modules. The
      # learning-module counts must still offer the other choice, because a
      # count of zero is a dead end and a count that ignores the agent lies.
      result = Index.filter(index(), %{"agent" => "surf", "modules" => "5"})
      learning_module = Enum.find(result.facets, &(&1.key == "learning_module"))

      assert learning_module.values == [%{value: "evidence", label: "evidence", count: 1}]
    end

    test "a facet never counts itself" do
      result = Index.filter(index(), %{"agent" => "surf"})
      agent = Enum.find(result.facets, &(&1.key == "agent"))

      assert Enum.sort_by(agent.values, & &1.value) == [
               %{value: "dist", label: "distant", count: 1},
               %{value: "surf", label: "surface", count: 2}
             ]
    end

    test "module counts are ordered by number, not by text" do
      result = Index.filter(index(), %{})
      modules = Enum.find(result.facets, &(&1.key == "modules"))

      assert Enum.map(modules.values, & &1.value) == ["1", "5"]
    end
  end

  # Whether an experiment runs here is a fact about the application, not about the
  # config, so the index is told it rather than deriving it. What it must do is
  # keep the answer, filter on it, and say "unknown" where it was told nothing.
  describe "whether an experiment runs here" do
    defp rated do
      Index.build(
        [
          experiment(
            "dist_1lm",
            "habitat_ycb_dist_agent_semantics0",
            "evidence_1lm_nn5_dod003",
            "1lm_1sm"
          ),
          experiment(
            "surf_5lm",
            "habitat_ycb_surf_agent_semantics0",
            "evidence_5lm_nn10_dod003",
            "5lm_5sm"
          ),
          experiment(
            "surf_1lm_scratch",
            "habitat_ycb_surf_agent_semantics0",
            "displacement_1lm",
            "1lm_1sm"
          )
        ],
        %{
          "dist_1lm" => %{ready: "yes", world: "mujoco"},
          "surf_5lm" => %{ready: "no", world: "mujoco"}
        }
      )
    end

    test "is the first facet, because it is the answer a reader comes for" do
      assert hd(rated().facets).key == "ready"
    end

    test "the world the config names is the second, because it decides the first" do
      assert Enum.map(rated().facets, & &1.key) |> Enum.take(2) == ["ready", "world"]
    end

    test "a row carries the verdict it was given, and says so when there was none" do
      entries = Map.new(rated().entries, &{&1.name, &1.ready})

      assert entries["surf_5lm"] == "no"
      assert entries["surf_1lm_scratch"] == "unknown"
    end

    test "keeps only the world asked for" do
      kept = Index.filter(rated(), %{"world" => "mujoco"})
      dropped = Index.filter(rated(), %{"world" => "habitat"})

      assert kept.matching == 2
      assert dropped.matching == 0
    end

    test "says the world in the row's own words" do
      assert Index.label("world", "mujoco") == "MuJoCo"
      assert Index.label("world", "habitat") == "Habitat"
    end

    test "keeps only what runs here, and only what does not" do
      runs = Index.filter(rated(), %{"ready" => "yes"})
      refused = Index.filter(rated(), %{"ready" => "no"})

      assert Enum.map(runs.entries, & &1.name) == ["dist_1lm"]
      assert Enum.map(refused.entries, & &1.name) == ["surf_5lm"]
    end

    test "counts under the other filters, like every other facet" do
      result = Index.filter(rated(), %{"agent" => "surf"})
      ready = Enum.find(result.facets, &(&1.key == "ready"))

      assert Enum.sort_by(ready.values, & &1.value) == [
               %{value: "no", label: "cannot run here", count: 1},
               %{value: "unknown", label: "unknown", count: 1}
             ]
    end

    test "reads as the question it answers, not as the stored value" do
      assert Index.label("ready", "yes") == "runs here"
      assert Index.label("ready", "waiting") == "waiting for prerequisites"
      assert Index.label("ready", "no") == "cannot run here"
      assert Index.label("ready", "not_planned") == "not planned"
    end

    # What a person reads, in the order they want it: what I can run, what would
    # run once a download finishes, what this build cannot run, and what has
    # been postponed.
    test "offers a postponed experiment its own answer, after the refusals" do
      index =
        Index.build(
          [
            experiment(
              "dist_1lm",
              "habitat_ycb_dist_agent_semantics0",
              "evidence_1lm_nn5_dod003",
              "1lm_1sm"
            ),
            experiment(
              "cows_large",
              "habitat_ycb_dist_agent_semantics0",
              "evidence_1lm_nn5_dod003",
              "1lm_1sm"
            ),
            experiment(
              "surf_5lm",
              "habitat_ycb_surf_agent_semantics0",
              "evidence_5lm_nn10_dod003",
              "5lm_5sm"
            ),
            experiment(
              "surf_1lm_scratch",
              "habitat_ycb_surf_agent_semantics0",
              "displacement_1lm",
              "1lm_1sm"
            )
          ],
          %{
            "dist_1lm" => %{ready: "yes", world: "mujoco"},
            "cows_large" => %{ready: "waiting", world: "mujoco"},
            "surf_5lm" => %{ready: "no", world: "mujoco"},
            "surf_1lm_scratch" => %{ready: "not_planned", world: "habitat"}
          }
        )

      ready = Enum.find(index.facets, &(&1.key == "ready"))

      assert Enum.map(ready.values, & &1.label) == [
               "runs here",
               "waiting for prerequisites",
               "cannot run here",
               "not planned"
             ]

      assert Enum.map(ready.values, & &1.value) == ["yes", "waiting", "no", "not_planned"]
    end
  end
end
