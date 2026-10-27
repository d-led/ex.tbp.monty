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
end
