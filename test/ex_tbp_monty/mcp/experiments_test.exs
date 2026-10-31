defmodule ExTbpMonty.Mcp.ExperimentsTest do
  use ExTbpMonty.DataCase, async: false

  alias ExTbpMonty.Mcp.Experiments
  alias Monty.Studio
  alias Monty.Studio.RunHistory
  alias Monty.Test.Tmp

  @experiment "tutorial/first_experiment"

  @run_attributes %{
    experiment: "tutorial/first_experiment",
    source: "monty",
    steps: 3,
    seed: 42,
    config: %{},
    inputs: %{}
  }

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

      # The questions a caller asks next, answered in the same response.
      assert summary.counts.sensors == 2
      assert summary.counts.learning_modules == 1
      # Either the config names its objects or the interface places them; what
      # matters is that the answer says which, not that this experiment uses one.
      assert %{source: source} = summary.objects
      assert source != ""
      assert %{num_parallel: parallel} = summary.parallel
      assert is_integer(parallel)
    end

    test "is an error for a name that is not an experiment" do
      assert {:error, message} = Experiments.describe("no/such/experiment")
      assert message =~ "no/such/experiment"
    end
  end

  describe "the experiments that can be opened" do
    test "says how many there are, and what shapes they come in" do
      index = Experiments.list()

      assert index.total > 200
      assert index.matching == index.total
      assert index.returned == index.matching or index.truncated?

      # The four choices a person asks about, each with the counts the page shows.
      assert Enum.map(index.facets, & &1.key) == ~w(agent modules learning_module model)

      agents = Enum.find(index.facets, &(&1.key == "agent"))
      assert Enum.sum(Enum.map(agents.values, & &1.count)) == index.total
    end

    test "narrows by a facet, and says how much of the whole it kept" do
      index = Experiments.list(agent: "surf")

      assert index.matching < index.total
      assert index.experiments != []
      assert Enum.all?(index.experiments, &(&1.agent == "surf"))
    end

    test "counts the choices with the other filters applied" do
      # "18 surf experiments, of which 9 start from a pretrained model" — the
      # count answers the next question, not the first one again.
      index = Experiments.list(agent: "surf")

      model = Enum.find(index.facets, &(&1.key == "model"))
      counted = Enum.sum(Enum.map(model.values, & &1.count))

      assert counted == index.matching
    end

    test "can be narrowed to the ones that choose an option in a group" do
      index = Experiments.list(group: "monty/learning_module", option: "displacement_1lm")

      refute index.experiments == []

      assert Enum.all?(
               index.experiments,
               &(&1.groups["monty/learning_module"] == "displacement_1lm")
             )
    end

    test "can be narrowed by a word in what they say about themselves" do
      index = Experiments.list(query: "first_experiment")
      assert @experiment in Enum.map(index.experiments, & &1.name)
    end

    test "is a page, so a caller is never handed two hundred rows" do
      first = Experiments.list(limit: 5)
      second = Experiments.list(limit: 5, offset: 5)

      assert length(first.experiments) == 5
      assert first.truncated?
      assert first.offset == 0
      assert second.offset == 5
      assert MapSet.disjoint?(MapSet.new(first.experiments), MapSet.new(second.experiments))
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

  describe "deleting runs" do
    test "answers what it would delete, and deletes nothing" do
      run = settled("failed")

      assert {:ok, answer} = Experiments.delete_runs(run_ids: [run.id])

      assert answer.deleted == 0
      assert [%{run_id: id, status: "failed"}] = answer.would_delete
      assert id == run.id
      assert RunHistory.get(run.id) != nil, "a dry run must not delete anything"
    end

    test "deletes a settled run once it is confirmed" do
      run = settled("stopped")

      assert {:ok, answer} = Experiments.delete_runs(run_ids: [run.id], confirm: true)

      assert answer.deleted == 1
      assert RunHistory.get(run.id) == nil
    end

    test "leaves a run that is still running alone, and says why" do
      {:ok, running} = RunHistory.start(@run_attributes)

      assert {:error, message} =
               Experiments.delete_runs(state: "running", confirm: true)

      assert message =~ "still running"
      assert RunHistory.get(running.id) != nil
    end

    test "names a run it cannot find rather than pretending it deleted it" do
      assert {:ok, answer} =
               Experiments.delete_runs(
                 run_ids: ["00000000-0000-0000-0000-000000000000"],
                 confirm: true
               )

      assert answer.deleted == 0
      assert answer.unknown_ids == ["00000000-0000-0000-0000-000000000000"]
    end

    test "covers a filtered set, which is what cleaning up means" do
      failed = settled("failed")
      finished = settled("finished")

      assert {:ok, answer} = Experiments.delete_runs(state: "failed", confirm: true)

      assert answer.deleted == 1
      assert RunHistory.get(failed.id) == nil
      assert RunHistory.get(finished.id) != nil
    end
  end

  defp settled(status) do
    {:ok, run} = RunHistory.start(@run_attributes)
    {:ok, run} = RunHistory.finish(run, %{}, status)
    run
  end
end
