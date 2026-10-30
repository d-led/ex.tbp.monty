defmodule ExTbpMonty.Mcp.ExperimentsTest do
  use ExTbpMonty.DataCase, async: false

  alias ExTbpMonty.Mcp.Experiments
  alias Monty.Studio
  alias Monty.Test.Tmp

  @experiment "tutorial/first_experiment"

  describe "an experiment's description" do
    test "says what it is made of" do
      assert {:ok, summary} = Experiments.describe(@experiment)

      assert summary.name == @experiment
      assert summary.sensors |> Enum.map(& &1.id) |> Enum.sort() == ["patch", "view_finder"]
      assert [%{id: "learning_module_0"} = learning_module] = summary.learning_modules
      assert is_map(learning_module.config)
      assert %{implemented: implemented, total: total} = summary.ported
      assert implemented >= 0 and total > 0
      assert %{train: _train, eval: _eval} = summary.epochs
    end

    test "is an error for a name that is not an experiment" do
      assert {:error, message} = Experiments.describe("no/such/experiment")
      assert message =~ "no/such/experiment"
    end
  end

  describe "the experiments that can be opened" do
    test "can be narrowed to the ones that choose an option in a group" do
      experiments = Experiments.list(group: "monty/learning_module", option: "displacement_1lm")

      refute experiments == []
      assert Enum.all?(experiments, &(&1.groups["monty/learning_module"] == "displacement_1lm"))
    end

    test "can be narrowed by a word in what they say about themselves" do
      assert @experiment in Enum.map(Experiments.list(query: "first_experiment"), & &1.name)
    end
  end

  describe "an option's parameters" do
    test "are the YAML Monty ships" do
      assert {:ok, found} = Experiments.option("monty/learning_module", "displacement_1lm")
      assert found.yaml =~ "_target_"
    end

    test "cannot be asked for where Monty has no such option" do
      assert {:error, message} = Experiments.option("monty/learning_module", "no-such-option")
      assert message =~ "monty_experiment_options"
    end

    test "and the options a group offers are files that exist" do
      assert {:ok, options} = Experiments.options("monty/learning_module")
      assert "displacement_1lm" in options
    end
  end

  describe "a preview" do
    test "composes the experiment you described, and nothing stops it running" do
      assert {:ok, preview} = Experiments.preview(%{"name" => "mcp_preview", "seed" => 7})

      assert preview.name == "mcp_preview"
      assert preview.yaml =~ "mcp_preview"
      assert preview.setup.seed == 7
      refute Enum.any?(preview.findings, &(&1.level == :error))
    end

    test "reports an option that does not exist instead of silently ignoring it" do
      assert {:ok, preview} =
               Experiments.preview(%{
                 "name" => "mcp_preview",
                 "monty/learning_module" => "no_such_module"
               })

      assert Enum.any?(preview.findings, &(&1.level == :error))
    end
  end

  describe "creating an experiment" do
    setup do
      Tmp.env_dir("mcp-drafts", :experiments_dir)
      :ok
    end

    test "writes a draft the studio can open" do
      assert {:ok, created} = Experiments.create(%{"name" => "mcp_draft", "seed" => 3})
      assert File.exists?(created.path)

      assert {:ok, opened} = Studio.open("mcp_draft")
      assert opened.source == :draft
      assert opened.setup.seed == 3
    end

    test "refuses a name that would not be a file name" do
      assert {:error, message} = Experiments.create(%{"name" => "../escape"})
      assert message =~ "not a usable experiment name"
    end
  end

  describe "running an experiment" do
    test "queues it and answers with the record it created" do
      assert {:ok, run} = Experiments.run(@experiment, 2)

      assert run.experiment == @experiment
      assert run.steps == 2
      assert run.status == "running"
    end

    test "reports what the run has done so far" do
      {:ok, run} = Experiments.run(@experiment, 2)

      assert {:ok, report} = Experiments.report(run.run_id)
      assert report.run_id == run.run_id
      assert report.steps == 2
      assert report.steps_done >= 0
    end

    test "has nothing to report for a run that does not exist" do
      assert {:error, message} = Experiments.report("00000000-0000-0000-0000-000000000000")
      assert message =~ "monty_list_runs"
    end
  end
end
