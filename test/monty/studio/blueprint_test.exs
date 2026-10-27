defmodule Monty.Studio.BlueprintTest do
  use ExUnit.Case, async: true

  alias Monty.Config.Composer
  alias Monty.Studio.{Blueprint, Catalog}

  describe "the least a person has to say" do
    test "a name is enough for a complete experiment" do
      blueprint = Blueprint.new(%{"name" => "my_experiment"})

      assert Blueprint.findings(blueprint) == []
      assert {:ok, tree} = Blueprint.compose(blueprint)
      assert tree["experiment"]["config"]["monty_config"]["sensor_modules"] != %{}
    end

    test "the default base is one of Monty's own experiments" do
      assert Blueprint.new(%{"name" => "my_experiment"}).base == "tutorial/first_experiment"
    end

    test "the run name follows the experiment name" do
      blueprint = Blueprint.new(%{"name" => "my_experiment"}) |> Blueprint.put_name("renamed")

      assert get_in(Blueprint.compose(blueprint) |> elem(1), [
               "experiment",
               "config",
               "logging",
               "run_name"
             ]) == "renamed"
    end
  end

  describe "a blueprint reproduces what it started from" do
    # The strongest promise this module can make, and the one that keeps it
    # honest: written out and composed, a blueprint *is* the experiment it came
    # from — because the generated text is composed through Monty's root config,
    # exactly as Monty's launcher composes a file in `conf/experiment/`.
    for name <- [
          "tutorial/first_experiment",
          "base_config_10distinctobj_dist_agent",
          "test/run",
          "randrot_noise_10distinctobj_5lms_dist_agent"
        ] do
      test "#{name} composes to the same tree" do
        blueprint = Blueprint.from_experiment(unquote(name))

        assert Blueprint.compose(blueprint) == Composer.compose(unquote(name))
      end

      test "#{name} keeps the group choices" do
        blueprint = Blueprint.from_experiment(unquote(name))
        original = Catalog.experiment(unquote(name))

        assert Map.new(Blueprint.groups(blueprint)) == original.groups
      end
    end
  end

  describe "changing one component" do
    test "a different learning module changes the learning module, not the sensors" do
      blueprint =
        Blueprint.new(%{"name" => "evidence_run"})
        |> Blueprint.put_group("monty/learning_module", "evidence_1lm_nn5_dod003")

      learning_modules =
        get_in(elem(Blueprint.compose(blueprint), 1), [
          "experiment",
          "config",
          "monty_config",
          "learning_modules"
        ])

      assert get_in(learning_modules, ["learning_module_0", "_target_"]) ==
               "tbp.monty.frameworks.models.evidence_matching.learning_module.EvidenceGraphLM"
    end

    test "a group the base does not use is added rather than ignored" do
      blueprint =
        Blueprint.new(%{"name" => "attention_run"})
        |> Blueprint.put_group("monty/attention_system", "default")

      assert {"monty/attention_system", "default"} in Blueprint.groups(blueprint)
    end
  end

  describe "what the checks catch before anything runs" do
    test "an option Monty does not have" do
      blueprint =
        Blueprint.new(%{"name" => "typo"})
        |> Blueprint.put_group("monty/learning_module", "not_a_learning_module")

      assert :unknown_group_option in codes(blueprint)
    end

    test "a base Monty does not have" do
      assert :unknown_base in codes(
               Blueprint.new(%{"name" => "x", "base" => "no/such/experiment"})
             )
    end

    test "a name that is not a file name" do
      assert :name_not_a_file_name in codes(Blueprint.new(%{"name" => "two words"}))
    end

    test "an epoch count that is not a count" do
      assert :epochs_not_a_count in codes(
               Blueprint.new(%{"name" => "x", "n_train_epochs" => "many"})
             )
    end

    test "a seed that is not a number" do
      assert :seed_not_a_number in codes(Blueprint.new(%{"name" => "x", "seed" => "random"}))
    end
  end

  defp codes(blueprint), do: blueprint |> Blueprint.findings() |> Enum.map(& &1.code)
end
