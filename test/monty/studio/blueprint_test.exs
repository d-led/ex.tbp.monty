defmodule Monty.Studio.BlueprintTest do
  use ExUnit.Case, async: true

  alias Monty.Config.Composer
  alias Monty.Studio.{Blueprint, Catalog, Setup}

  describe "the least a person has to say" do
    test "a name is enough for an experiment the port can start" do
      blueprint = Blueprint.new(%{"name" => "my_experiment"})

      assert Blueprint.findings(blueprint) == []
      assert {:ok, tree} = Blueprint.compose(blueprint)
      assert tree["experiment"]["config"]["monty_config"]["sensor_modules"] != %{}

      # The promise the builder makes: save without touching anything and the
      # draft is one a run accepts. It was not — the default base named classes
      # this port had not written.
      assert {:ok, setup} = Setup.from_text(Blueprint.to_yaml(blueprint), name: "my_experiment")
      assert Setup.valid?(setup)
    end

    test "the default base is a template, which is an experiment this port runs" do
      blueprint = Blueprint.new(%{"name" => "my_experiment"})

      assert blueprint.base in Catalog.templates()
      assert blueprint.base == "base_config_10distinctobj_dist_agent"
    end

    test "a base that states its epochs as a constant is not refused for it" do
      # `n_eval_epochs: ${constants.rotations_all_count}` is 14 by the time a run
      # is built; validating the text refused the experiment the acceptance
      # ladder runs. The text is kept all the same, because a draft has to
      # compose to the experiment it came from.
      blueprint = Blueprint.from_experiment("base_config_10distinctobj_dist_agent")

      assert blueprint.config["n_eval_epochs"] == "${constants.rotations_all_count}"
      assert Blueprint.findings(blueprint) == []
      assert {:ok, tree} = Blueprint.compose(blueprint)

      assert get_in(tree, ["experiment", "config", "n_eval_epochs"]) ==
               "${constants.rotations_all_count}"
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
          "randrot_noise_10distinctobj_5lms_dist_agent",
          # An experiment of ours, in one of our own sets: the builder offers
          # these as starting points, so a base has to be read from the tree
          # the studio composes from and not from Monty's mirror alone.
          "cad/plate_part_eval"
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
    # The failure this pins was silent: an unreadable base keeps the builder
    # usable by falling back to a template, so the result composed — as a
    # different experiment, in a different world, with nothing saying so.
    test "a base this application defines is read from its own set" do
      blueprint = Blueprint.from_experiment("cad/plate_part_eval")

      assert blueprint.base == "cad/plate_part_eval"
      assert {"environment", "cad_plate_objects"} in Blueprint.groups(blueprint)
      refute Enum.any?(Blueprint.findings(blueprint), &(&1.code == :unknown_base))
    end

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

    # The builder offers the options every root the page reads from; a check
    # that consulted only Monty's own tree would refuse a choice the page had
    # just offered, which is how `displacement_2lm` (a set of ours) read as a
    # typo while it sat in the select.
    test "an option from another config root is a choice, not an error" do
      blueprint =
        Blueprint.new(%{"name" => "x"})
        |> Blueprint.put_group("monty/learning_module", "displacement_2lm")

      refute :unknown_group_option in codes(blueprint)
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
