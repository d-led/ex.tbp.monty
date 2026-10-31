defmodule Monty.Config.ComposerTest do
  use ExUnit.Case, async: true

  alias Monty.Config.{Composer, SnapshotCheck, Source}

  @moduletag :monty_source

  setup_all do
    if File.dir?(Source.conf_dir()) do
      :ok
    else
      {:ok, unavailable: true}
    end
  end

  describe "compose/2" do
    test "places the active experiment's keys at experiment.config", context do
      skip_without_source(context)

      assert {:ok, config} = Composer.compose("randrot_noise_10distinctobj_dist_agent")

      assert get_in(config, ["experiment", "config", "monty_config", "monty_class"]) ==
               "${monty.class:tbp.monty.frameworks.models.evidence_matching.model.MontyForEvidenceGraphMatching}"
    end

    test "keeps the connectivity wiring exactly as written", context do
      skip_without_source(context)

      assert {:ok, config} = Composer.compose("randrot_noise_10distinctobj_dist_agent")
      monty_config = get_in(config, ["experiment", "config", "monty_config"])

      assert monty_config["sm_to_agent_dict"] == %{
               "patch" => "agent_id_0",
               "view_finder" => "agent_id_0"
             }

      assert monty_config["sm_to_lm_matrix"] == [[0]]
      assert monty_config["lm_to_lm_matrix"] == nil
      assert monty_config["lm_to_lm_vote_matrix"] == nil
    end

    test "a nested default lands at the package its parent names", context do
      skip_without_source(context)

      assert {:ok, config} = Composer.compose("randrot_noise_10distinctobj_dist_agent")

      learning_module =
        get_in(config, [
          "experiment",
          "config",
          "monty_config",
          "learning_modules",
          "learning_module_0"
        ])

      assert learning_module["hypotheses_updater_class"] ==
               "${monty.class:tbp.monty.frameworks.models.evidence_matching.burst_sampling.BurstSamplingHypothesesUpdater}"

      assert learning_module["hypotheses_updater_args"] == %{"max_nneighbors" => 10}
    end

    test "Monty's own defaults are folded in before the experiment's overrides", context do
      skip_without_source(context)

      assert {:ok, config} = Composer.compose("randrot_noise_10distinctobj_dist_agent")

      # experiment.yaml sets do_eval: false; base_config sets do_eval: true.
      assert get_in(config, ["experiment", "config", "do_eval"]) == true
      # The root's own keys survive where no experiment overrides them.
      assert config["episodes"] == "all"
      assert config["num_parallel"] == 16
    end

    test "reports a config file that does not exist instead of composing a partial tree",
         context do
      skip_without_source(context)

      assert {:error, {:cannot_read, path, :enoent}} = Composer.compose("no_such_experiment")
      assert path =~ "no_such_experiment.yaml"
    end
  end

  describe "every snapshot Monty ships" do
    test "composes to the same tree", context do
      skip_without_source(context)

      # `{:ok, count}` is the whole claim: every snapshot composed to the tree
      # Monty recorded for it. The floor only proves the walk read the directory —
      # a check that compared nothing would pass silently. Monty at `760ad174`
      # ships 54, because the pull folded the MuJoCo presets into the defaults and
      # deleted their snapshots.
      assert {:ok, count} = SnapshotCheck.run()
      assert count >= 50
    end
  end

  defp skip_without_source(context) do
    if context[:unavailable] do
      flunk("Monty checkout not found at #{Source.root()}; set MONTY_SOURCE")
    end
  end
end
