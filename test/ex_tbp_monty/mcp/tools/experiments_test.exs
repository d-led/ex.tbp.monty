defmodule ExTbpMonty.Mcp.Tools.ExperimentsTest do
  @moduledoc """
  The experiment and run tools, called the way a client calls them: by name, with
  a JSON object, answering text a person reads and data a program reads.

  The studio's own behaviour is held by `ExTbpMonty.Mcp.ExperimentsTest`. What is
  held here is the part a client depends on — which arguments are accepted, what
  the sentence says, and that a run answers with a link — because that is the
  whole of what an assistant sees of this application.
  """

  use ExTbpMonty.DataCase, async: false

  alias ExTbpMonty.Mcp.Tools
  alias Monty.Prerequisites
  alias Monty.Studio
  alias Monty.Studio.Drafts
  alias Monty.Studio.RunHistory
  alias Monty.Test.Tmp

  @ctx %{base_url: "http://studio.test"}
  @experiment "base_config_10distinctobj_dist_agent"

  describe "the catalog" do
    test "leads with how many experiments there are, not with two hundred rows" do
      assert {:ok, %{text: text, structured: index}} =
               Tools.call("monty_list_experiments", %{}, @ctx)

      assert index.total > 100
      assert length(index.experiments) < index.total
      assert text =~ "#{index.total} experiments."
      assert text =~ "Choices, each counted with the other filters applied:"
    end

    test "says how much of the whole a filter kept" do
      assert {:ok, %{text: text, structured: index}} =
               Tools.call("monty_list_experiments", %{"agent" => "surf"}, @ctx)

      assert index.matching < index.total
      assert text =~ "#{index.matching} of #{index.total} experiments match."
      assert Enum.all?(index.experiments, &(&1.agent == "surf"))
    end

    test "is a page, and names the argument that shows the next one" do
      assert {:ok, %{text: text, structured: index}} =
               Tools.call("monty_list_experiments", %{"limit" => 2}, @ctx)

      assert index.returned == 2
      assert text =~ "ask again with `offset: 2`"
    end

    test "says so when nothing matches" do
      assert {:ok, %{text: text}} =
               Tools.call("monty_list_experiments", %{"query" => "no such experiment"}, @ctx)

      assert text =~ "Nothing matches."
    end

    test "refuses an argument that is not a number, naming the argument" do
      assert {:error, message} =
               Tools.call("monty_list_experiments", %{"limit" => "many"}, @ctx)

      assert message =~ "`limit` must be an integer."
    end
  end

  describe "one experiment" do
    test "says what it is made of, in the page's own words" do
      assert {:ok, %{text: text, structured: summary}} =
               Tools.call("monty_describe_experiment", %{"name" => @experiment}, @ctx)

      assert text =~ @experiment
      # The same sentences the studio page shows and the CLI prints.
      assert text =~ "sensors: patch, view_finder"
      assert text =~ "episodes, as the config runs them: 140 eval"
      assert text =~ "ported here: #{summary.ported.implemented}/#{summary.ported.total}"
    end

    test "is an error for a name that is not an experiment" do
      assert {:error, message} =
               Tools.call("monty_describe_experiment", %{"name" => "no/such/experiment"}, @ctx)

      assert message =~ "not an experiment that opens"
    end

    test "says which world it steps, and that this one reads no files" do
      assert {:ok, %{text: text, structured: summary}} =
               Tools.call("monty_describe_experiment", %{"name" => @experiment}, @ctx)

      # The suite's world is this port's stand-in, which builds its own scene,
      # so a run of it has nothing to download first.
      assert summary.world == "synthetic"
      assert summary.needs == []
      assert text =~ "on disk: nothing"
    end

    # The answer `monty_run_experiment` gives as a refusal is an answer here too,
    # before anything is queued: what a run of this setup would have to read.
    test "says what a run of it would read off the disk, and what is missing" do
      Tmp.app_env(:world_simulator, :habitat)
      Tmp.system_env("MONTY_PYTHON", interpreter())
      Tmp.system_env("MONTY_DATA", Tmp.dir("monty-data"))
      Tmp.system_env("MONTY_MODELS", Tmp.dir("monty-models"))

      assert {:ok, %{text: text, structured: summary}} =
               Tools.call("monty_describe_experiment", %{"name" => @experiment}, @ctx)

      assert summary.world == "habitat"
      assert summary.needs != []
      assert text =~ ~r/on disk \(\d+\/#{length(summary.needs)} here\):/

      for need <- summary.needs do
        assert %{kind: kind, what: what, path: path, present?: present?} = need
        assert kind in [:interpreter, :engine, :data, :models]
        assert is_binary(what)
        # An engine that travels in the release has no path to point at.
        assert is_nil(path) or is_binary(path)
        assert is_boolean(present?)
      end

      # The interpreter and the engine are the ones this test named; the objects
      # are not here, and saying so is the point of the line.
      assert Enum.any?(summary.needs, &(&1.kind == :data and not &1.present?))
      assert text =~ "missing: the objects this environment loads"
    end

    test "the groups a config is built from are listed, and read one at a time" do
      assert {:ok, %{text: text, structured: %{groups: groups}}} =
               Tools.call("monty_experiment_options", %{}, @ctx)

      assert "monty/learning_module" in groups
      assert text =~ "- `monty/learning_module`"

      assert {:ok, %{text: options_text, structured: %{group: "monty/learning_module"}}} =
               Tools.call("monty_experiment_options", %{"group" => "monty/learning_module"}, @ctx)

      assert options_text =~ "displacement_1lm"
    end

    test "an option's own config file is the file, not a summary of it" do
      assert {:ok, %{text: text, structured: found}} =
               Tools.call(
                 "monty_read_option",
                 %{"group" => "monty/learning_module", "option" => "displacement_1lm"},
                 @ctx
               )

      assert found.yaml =~ "_target_"
      assert text =~ "```yaml"
    end

    test "refuses an option Monty does not ship" do
      assert {:error, message} =
               Tools.call(
                 "monty_read_option",
                 %{"group" => "monty/learning_module", "option" => "no_such_module"},
                 @ctx
               )

      assert message =~ "not a config Monty ships"
    end
  end

  describe "previewing and creating" do
    test "a preview composes the experiment you described" do
      assert {:ok, %{text: text, structured: preview}} =
               Tools.call(
                 "monty_preview_experiment",
                 %{"attributes" => %{"name" => "mcp_preview", "seed" => 7}},
                 @ctx
               )

      # No base named, so it starts from a template — an experiment this
      # application runs.
      assert text =~ "`mcp_preview` from `base_config_10distinctobj_dist_agent`"
      assert text =~ "```yaml"
      assert preview.yaml =~ "mcp_preview"
      refute text =~ "modules_not_ported"
    end

    test "a finding is part of the preview, not a reason to refuse it" do
      assert {:ok, %{text: text, structured: preview}} =
               Tools.call(
                 "monty_preview_experiment",
                 %{
                   "attributes" => %{
                     "name" => "mcp_preview",
                     "base" => "test/base_config/base"
                   }
                 },
                 @ctx
               )

      # That base is over Monty's own test fakes, which nothing here can place.
      # The preview is where a caller finds that out, in the same words the page
      # uses.
      assert text =~ "- error unknown_module_class"
      assert preview.yaml =~ "mcp_preview"
    end

    test "a preview reports the option that does not exist rather than ignoring it" do
      assert {:ok, %{text: text}} =
               Tools.call(
                 "monty_preview_experiment",
                 %{
                   "attributes" => %{
                     "name" => "mcp_preview",
                     "monty/learning_module" => "no_such_module"
                   }
                 },
                 @ctx
               )

      assert text =~ "- error "
    end

    test "creating answers with the link a person opens" do
      Tmp.env_dir("mcp-tool-drafts", :experiments_dir)

      assert {:ok, %{text: text, structured: created}} =
               Tools.call(
                 "monty_create_experiment",
                 %{"attributes" => %{"name" => "mcp_tool_draft", "seed" => 3}},
                 @ctx
               )

      assert created.name == "mcp_tool_draft"
      assert created.url == "http://studio.test/experiments/mcp_tool_draft"
      assert text =~ "Saved `mcp_tool_draft` as a draft."
    end
  end

  describe "a file" do
    test "exports a Monty experiment as the file a person would edit" do
      assert {:ok, %{text: text, structured: exported}} =
               Tools.call("monty_export_experiment", %{"name" => @experiment}, @ctx)

      assert exported.source == :monty
      assert exported.filename == "base_config_10distinctobj_dist_agent.yaml"
      assert text =~ "as `base_config_10distinctobj_dist_agent.yaml`"
      assert text =~ "```yaml"
    end

    test "says a file from somewhere else composes, and keeps it" do
      Tmp.env_dir("mcp-tool-import", :experiments_dir)
      {:ok, exported} = Drafts.export(@experiment)

      assert {:ok, %{text: text, structured: imported}} =
               Tools.call(
                 "monty_import_experiment",
                 %{"name" => "imported_tool_draft", "yaml" => exported.yaml},
                 @ctx
               )

      assert imported.valid?
      assert text =~ "It composes and nothing would stop it running."
      assert text =~ "http://studio.test/experiments/imported_tool_draft"
    end

    test "refuses a file that is not a config, and writes nothing" do
      Tmp.env_dir("mcp-tool-import", :experiments_dir)

      assert {:error, _message} =
               Tools.call(
                 "monty_import_experiment",
                 %{"name" => "not_a_config", "yaml" => "not: {a hydra config"},
                 @ctx
               )

      refute Drafts.exists?("not_a_config")
    end
  end

  describe "runs" do
    test "are listed with a link each, and the counts of the whole record" do
      run = settled("failed")

      assert {:ok, %{text: text, structured: page}} =
               Tools.call("monty_list_runs", %{}, @ctx)

      assert page.total >= 1
      assert [%{run_id: run_id, url: url} | _] = page.runs
      assert run_id == run.id
      assert url == "http://studio.test/runs/#{run.id}"
      assert text =~ "#{page.total} run(s) match"
      assert text =~ "http://studio.test/runs/#{run.id}"
    end

    test "say so when no run matches" do
      assert {:ok, %{text: text}} =
               Tools.call("monty_list_runs", %{"query" => "no_such_experiment_name"}, @ctx)

      assert text =~ "No run matches."
    end

    test "a new run answers with its link, and says which world it steps" do
      assert {:ok, %{text: text, structured: run}} =
               Tools.call("monty_run_experiment", %{"name" => @experiment, "steps" => 2}, @ctx)

      # The deployment's default when the caller does not choose, and said out
      # loud, because a stand-in scene and Monty's world answer different
      # questions.
      assert run.world == "synthetic"
      assert text =~ "Queued 2 step(s) of `#{@experiment}` in this port's synthetic scene."
      assert run.url == "http://studio.test/runs/#{run.run_id}"

      assert {:ok, %{text: report_text, structured: report}} =
               Tools.call("monty_run_report", %{"run_id" => run.run_id}, @ctx)

      assert report.run_id == run.run_id
      assert report_text =~ "`#{@experiment}` — "
      assert report_text =~ run.url
    end

    test "the world is the caller's choice, and the record keeps it" do
      experiment = draft_without_memory()
      download_prerequisites(experiment)

      assert {:ok, %{text: text, structured: run}} =
               Tools.call(
                 "monty_run_experiment",
                 %{"name" => experiment, "steps" => 1, "world" => "monty"},
                 @ctx
               )

      assert run.world == "mujoco"
      assert text =~ "in Monty's MuJoCo simulator, in this application"

      # What the queue will step is the record, not the worker's environment.
      record = RunHistory.get(run.run_id)
      assert record.inputs["world"] == "mujoco"
    end

    # The same rule the page holds, at the door an assistant comes in by: a
    # run id for a run that dies at its first step helps nobody. The answer is
    # the two things a caller can actually do about it.
    test "refuses a run whose files are not here yet, and says where to get them" do
      # "nothing was recorded" is a claim about an empty history.
      ExTbpMonty.Repo.delete_all(RunHistory.Run)
      Tmp.without_env("MONTY_PYTHON")
      Tmp.system_env("MONTY_DATA", Tmp.dir("monty-data"))
      Tmp.system_env("MONTY_MODELS", Tmp.dir("monty-models"))

      assert {:error, message} =
               Tools.call(
                 "monty_run_experiment",
                 %{"name" => @experiment, "steps" => 1, "world" => "monty"},
                 @ctx
               )

      assert message =~ "would not run"
      assert message =~ "Not on this machine yet"
      # A caller that cannot open a page needs the URL it would click: the
      # finding carries the download, and the message carries the finding.
      assert message =~ "/prerequisites?fetch=ycb_objects_1_0"

      assert RunHistory.search(state: "all", text: @experiment).runs == []
    end

    test "refuses a world no port here has" do
      assert {:error, message} =
               Tools.call(
                 "monty_run_experiment",
                 %{"name" => @experiment, "world" => "habitat2"},
                 @ctx
               )

      assert message =~ "`world` must be `synthetic` or `mujoco`"
    end

    test "a run nobody can find is named as missing" do
      assert {:error, message} =
               Tools.call(
                 "monty_run_report",
                 %{"run_id" => "00000000-0000-0000-0000-000000000000"},
                 @ctx
               )

      assert message =~ "No run `00000000-0000-0000-0000-000000000000`"
    end

    test "deleting asks first, and then deletes" do
      run = settled("failed")

      assert {:ok, %{text: asked, structured: dry}} =
               Tools.call("monty_delete_runs", %{"run_ids" => [run.id]}, @ctx)

      assert dry.deleted == 0
      assert asked =~ "This would delete 1 run(s)"
      assert asked =~ "Call again with `confirm: true` to delete them."
      assert RunHistory.get(run.id) != nil

      assert {:ok, %{text: done, structured: confirmed}} =
               Tools.call("monty_delete_runs", %{"run_ids" => [run.id], "confirm" => true}, @ctx)

      assert confirmed.deleted == 1
      assert done =~ "Deleted 1 run(s), with the files they wrote:"
      assert RunHistory.get(run.id) == nil
    end

    test "names the runs left alone because they are still running" do
      {:ok, running} =
        RunHistory.start(run_attributes()) |> then(fn {:ok, r} -> RunHistory.mark_running(r) end)

      settled("failed")

      assert {:ok, %{text: text, structured: answer}} =
               Tools.call(
                 "monty_delete_runs",
                 %{"state" => "all", "confirm" => true},
                 @ctx
               )

      assert [%{run_id: refused_id, status: "running"}] = answer.refused_running
      assert refused_id == running.id
      assert text =~ "Left alone because they are still running:"
      assert RunHistory.get(running.id) != nil
    end

    test "names an id no run answers, rather than pretending it deleted it" do
      missing = "00000000-0000-0000-0000-000000000000"

      assert {:ok, %{text: text, structured: answer}} =
               Tools.call("monty_delete_runs", %{"run_ids" => [missing], "confirm" => true}, @ctx)

      assert answer.unknown_ids == [missing]
      assert text =~ "No such run: #{missing}"
    end

    test "reads a confirmation strictly: a word it does not know is an error" do
      assert {:error, message} =
               Tools.call("monty_delete_runs", %{"confirm" => "maybe"}, @ctx)

      assert message =~ "`confirm` must be true or false."
    end
  end

  defp run_attributes do
    %{
      experiment: @experiment,
      source: "monty",
      steps: 3,
      seed: 42,
      config: %{},
      inputs: %{}
    }
  end

  defp settled(status) do
    {:ok, run} = RunHistory.start(run_attributes())
    {:ok, run} = RunHistory.finish(run, %{}, status)
    run
  end

  # Every file a run of the test experiment reads, created where this port looks
  # for it: the refusal above is about files, so a test about the world must not
  # be a test about files.
  defp download_prerequisites(experiment) do
    Tmp.system_env("MONTY_PYTHON", interpreter())
    Tmp.system_env("MONTY_DATA", Tmp.dir("monty-data"))
    Tmp.system_env("MONTY_MODELS", Tmp.dir("monty-models"))

    {:ok, opened} = Studio.open(experiment, world_simulator: :habitat)

    # Only the downloads are directories to create: the interpreter and the
    # engine are packages inside it, and their path is the interpreter itself.
    # A directory that holds nothing is not data, so each one keeps a file.
    for %{kind: kind, path: path} <- Prerequisites.for_setup(opened.setup),
        kind in [:data, :models] do
      File.mkdir_p!(path)
      File.write!(Path.join(path, "downloaded-by-the-test"), "")
    end
  end

  # The acceptance config with its memory taken out: a config whose prerequisites
  # are directories, so a test about which world a run records does not have to
  # fabricate a pretrained library. An empty `.jsonl.gz` is a corrupt library,
  # and one written into the shipped directory poisons every later test in this
  # node — which is exactly what happened once.
  defp draft_without_memory do
    Tmp.env_dir("mcp-tool-drafts", :experiments_dir)

    yaml =
      Path.join([:code.priv_dir(:ex_tbp_monty), "monty/conf/experiment/#{@experiment}.yaml"])
      |> File.read!()
      |> String.replace(
        "model_name_or_path: ${constants.pretrained_dir}/surf_agent_1lm_10distinctobj/pretrained/",
        "model_name_or_path: \"\""
      )

    {:ok, _draft} = Drafts.import("world_choice_eval", yaml, overwrite: true)
    "world_choice_eval"
  end

  # An interpreter that answers every import with success. These tests are about
  # which world a run records and which files it reads, not about whether MuJoCo
  # is installed on the machine running them.
  defp interpreter do
    path = Tmp.file("python")
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)
    path
  end
end
