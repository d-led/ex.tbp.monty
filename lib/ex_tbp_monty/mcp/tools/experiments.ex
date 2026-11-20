defmodule ExTbpMonty.Mcp.Tools.Experiments do
  @moduledoc """
  Experiments: what they are, what they can be, and starting one.

  Reading and running are different promises, so the tools are named apart. The
  tools that only read (`monty_list_experiments` … `monty_experiment_options`)
  are annotated read-only. Two write: `monty_create_experiment` saves a draft and
  `monty_run_experiment` queues a job — both of them the studio's own operations,
  and both answering with a link a person can open.

  A run is queued, not awaited: it steps at its own pace in the studio's queue,
  and `monty_run_report` answers what it has done so far. Waiting here would tie
  an HTTP request to an experiment's runtime, which is the thing the queue
  exists to avoid.
  """

  alias ExTbpMonty.Mcp.{Args, Experiments}
  alias Monty.Studio.RunHistory.Part

  @doc "`monty_list_experiments`: how many there are, and what shapes they come in."
  def list(args, _ctx) do
    with {:ok, query} <- Args.optional(args, "query"),
         {:ok, group} <- Args.optional(args, "group"),
         {:ok, option} <- Args.optional(args, "option"),
         {:ok, ready} <- Args.optional(args, "ready"),
         {:ok, world} <- Args.optional(args, "world"),
         {:ok, agent} <- Args.optional(args, "agent"),
         {:ok, modules} <- Args.optional(args, "modules"),
         {:ok, learning_module} <- Args.optional(args, "learning_module"),
         {:ok, model} <- Args.optional(args, "model"),
         {:ok, limit} <- Args.integer(args, "limit", default: 25, min: 1, max: 200),
         {:ok, offset} <- Args.integer(args, "offset", default: 0, min: 0, max: 10_000) do
      index =
        Experiments.list(
          query: query,
          group: group,
          option: option,
          ready: ready,
          world: world,
          agent: agent,
          modules: modules,
          learning_module: learning_module,
          model: model,
          limit: limit,
          offset: offset
        )

      {:ok, %{text: list_text(index), structured: index}}
    end
  end

  @doc "`monty_describe_experiment`: the setup, its parameters, and its port status."
  def describe(args, _ctx) do
    with {:ok, name} <- Args.required(args, "name"),
         {:ok, summary} <- Experiments.describe(name) do
      {:ok, %{text: describe_text(summary), structured: summary}}
    end
  end

  @doc "`monty_experiment_options`: the groups, or one group's options."
  def options(args, _ctx) do
    with {:ok, group} <- Args.optional(args, "group") do
      case group do
        nil -> {:ok, %{text: groups_text(), structured: %{groups: Experiments.groups()}}}
        group -> options_of(group)
      end
    end
  end

  defp options_of(group) do
    with {:ok, options} <- Experiments.options(group) do
      {:ok,
       %{
         text:
           "`#{group}`: " <>
             Enum.join(options, ", ") <>
             "\n\n" <>
             "Read one with monty_read_option.",
         structured: %{group: group, options: options}
       }}
    end
  end

  @doc "`monty_read_option`: one option's config file, where its parameters are."
  def read_option(args, _ctx) do
    with {:ok, group} <- Args.required(args, "group"),
         {:ok, option} <- Args.required(args, "option"),
         {:ok, %{yaml: yaml} = found} <- Experiments.option(group, option) do
      {:ok,
       %{
         text: "`#{group}/#{option}` — #{found.path}\n\n```yaml\n" <> yaml <> "\n```",
         structured: found
       }}
    end
  end

  @doc "`monty_preview_experiment`: what a blueprint would compose to."
  def preview(args, _ctx) do
    with {:ok, attributes} <- Args.object(args, "attributes"),
         {:ok, preview} <- Experiments.preview(attributes) do
      {:ok, %{text: preview_text(preview), structured: preview}}
    end
  end

  @doc "`monty_create_experiment`: save a blueprint as a draft."
  def create(args, ctx) do
    with {:ok, attributes} <- Args.object(args, "attributes"),
         {:ok, created} <- Experiments.create(attributes) do
      url = ctx.base_url <> "/experiments/" <> created.name

      {:ok,
       %{
         text:
           "Saved `#{created.name}` as a draft.\n#{url}\n\n```yaml\n" <> created.yaml <> "\n```",
         structured: Map.put(created, :url, url)
       }}
    end
  end

  @doc "`monty_export_experiment`: the experiment as a file."
  def export_experiment(args, ctx) do
    with {:ok, name} <- Args.required(args, "name"),
         {:ok, exported} <- Experiments.export(name) do
      url = ctx.base_url <> "/export/experiments/" <> exported.name

      {:ok,
       %{
         text:
           "`#{exported.name}` as `#{exported.filename}` (#{exported.source}, the file you " <>
             "would edit — not what it composes to).\n#{url}\n\n```yaml\n" <>
             exported.yaml <> "\n```",
         structured: Map.put(exported, :url, url)
       }}
    end
  end

  @doc "`monty_import_experiment`: keep an experiment file from somewhere else."
  def import_experiment(args, ctx) do
    with {:ok, name} <- Args.required(args, "name"),
         {:ok, yaml} <- Args.required(args, "yaml"),
         {:ok, overwrite} <- Args.boolean(args, "overwrite"),
         {:ok, imported} <- Experiments.import(name, yaml, overwrite: overwrite) do
      url = ctx.base_url <> "/experiments/" <> imported.name

      verdict =
        if imported.valid?,
          do: "It composes and nothing would stop it running.",
          else: "It is saved, but it would not run as it stands:"

      {:ok,
       %{
         text:
           "Saved `#{imported.name}` as a draft. #{verdict}\n#{url}\n\n" <>
             findings_text(imported.findings),
         structured: Map.put(imported, :url, url)
       }}
    end
  end

  @doc "`monty_run_experiment`: queue a run, and answer with its link."
  def run(args, ctx) do
    with {:ok, name} <- Args.required(args, "name"),
         {:ok, steps} <- Args.integer(args, "steps", default: nil, min: 1, max: nil),
         {:ok, world} <- world(args),
         {:ok, run} <- Experiments.run(name, steps, world: world) do
      url = ctx.base_url <> "/runs/" <> run.run_id

      {:ok,
       %{
         text:
           "Queued #{steps} step(s) of `#{run.experiment}` in #{world_name(run.world)}.\n" <>
             "#{url}\n" <>
             "Run id: `#{run.run_id}`. Watch it at the link, or ask " <>
             "monty_run_report for what it has done.",
         structured: Map.put(run, :url, url)
       }}
    end
  end

  # `world` is the same choice the run page offers, in the words the page and
  # Monty's configs use: Monty's own simulator answers a different question from
  # this port's stand-in scene, so the caller says which one it wants. A world
  # this node cannot step is not offered: which ones it can is a question about
  # the node (`ex_mujoco`'s compiled binding, `ex_monty_cad`'s part), and
  # `Monty.Studio.Setup.worlds/0` is where that is answered.

  # Every word a caller may say and the world it means, in one table — `monty` is
  # the spelling Monty's own configs use for the world `mujoco` names, so a
  # caller who copied it from a config is answered rather than corrected. One
  # table because a word offered and unmapped, or mapped and not offered, is the
  # shape this had: a list kept here said the tool accepted four worlds while the
  # run page offered five, and `ex_mujoco` — the compiled binding this
  # application started carrying — was refused with a sentence naming the others.
  @words [
    {"monty", :mujoco},
    {"mujoco", :mujoco},
    {"ex_mujoco", :ex_mujoco},
    {"synthetic", :synthetic},
    {"image", :image},
    {"omniglot", :omniglot},
    {"cad", :cad}
  ]

  @by_word Map.new(@words)

  @doc """
  The words `world` accepts, which is also the schema's `enum`.

  The vocabulary, not this node's abilities: a word here that a node cannot step
  is answered with the sentence saying what would make it work (`cad` without
  `ex_monty_cad` says so), and a caller is better served by that than by a
  schema that hides the question. What must not happen is the other direction —
  a world this application carries with no word for it, which is what `ex_mujoco`
  was: the run page offered it and this tool refused it with a list of the
  worlds it did know.

  `monty` is one of the words because it is the spelling Monty's own configs use
  for the world `mujoco` names, so a caller who copied it from a config is
  answered rather than corrected.
  """
  @spec worlds() :: [String.t()]
  def worlds, do: Enum.map(@words, &elem(&1, 0))

  defp world(args) do
    with {:ok, word} <- Args.optional(args, "world") do
      cond do
        is_nil(word) ->
          {:ok, nil}

        word in worlds() ->
          {:ok, Map.fetch!(@by_word, word)}

        true ->
          {:error,
           "`world` must be one of #{Enum.map_join(worlds(), ", ", &"`#{&1}`")}, not `#{word}`."}
      end
    end
  end

  # One sentence a world, kept as a table beside `@words` rather than as a clause
  # each: a world added to the enum is a line here, and the function stays one
  # lookup however many worlds there are (`world_of/1` in the run job has the same
  # shape for the same reason).
  @world_notes %{
    "mujoco" => "Monty's MuJoCo simulator, in this application",
    "ex_mujoco" => "that same scene, stepped by the compiled binding this release carries",
    "synthetic" => "this port's synthetic scene",
    "image" =>
      "captured scenes — photographs with their depth — opened from the config's data path",
    "omniglot" => "the Omniglot dataset's characters, traced along the pen path that drew them",
    "cad" => "a CAD part, stepped through ex_monty_cad"
  }

  # A world in the enum with no sentence here is a sentence short, and saying
  # "the stand-in scene" about it would be a description of another run.
  defp world_name(world),
    do: Map.get(@world_notes, world, "#{world}, a world this description does not know")

  @doc "`monty_run_report`: what a run did, and what it is doing."
  def run_report(args, ctx) do
    with {:ok, run_id} <- Args.required(args, "run_id"),
         {:ok, report} <- Experiments.report(run_id) do
      url = ctx.base_url <> "/runs/" <> report.run_id

      {:ok, %{text: report_text(report, url), structured: Map.put(report, :url, url)}}
    end
  end

  @doc "`monty_list_runs`: the runs a filter matches, each with a link."
  def list_runs(args, ctx) do
    with {:ok, state} <- Args.optional(args, "state"),
         {:ok, query} <- Args.optional(args, "query"),
         {:ok, page} <- Args.integer(args, "page", default: 1, min: 1, max: 1000),
         {:ok, limit} <- Args.integer(args, "limit", default: 10, min: 1, max: 50) do
      runs = Experiments.runs(state: state, query: query, page: page, limit: limit)

      {:ok,
       %{
         text: runs_text(runs, ctx.base_url),
         structured:
           Map.put(runs, :runs, Enum.map(runs.runs, &Map.put(&1, :url, run_url(&1, ctx))))
       }}
    end
  end

  @doc "`monty_delete_runs`: forgets runs, and says what it would forget first."
  def delete_runs(args, _ctx) do
    with {:ok, run_ids} <- Args.strings(args, "run_ids"),
         {:ok, state} <- Args.optional(args, "state"),
         {:ok, query} <- Args.optional(args, "query"),
         {:ok, confirm} <- Args.boolean(args, "confirm"),
         {:ok, deleted} <-
           Experiments.delete_runs(
             run_ids: run_ids,
             state: state,
             query: query,
             confirm: confirm
           ) do
      {:ok, %{text: delete_text(deleted), structured: deleted}}
    end
  end

  defp run_url(%{run_id: run_id}, ctx), do: ctx.base_url <> "/runs/" <> run_id

  # -- text ------------------------------------------------------------------

  defp groups_text do
    "The groups a config is built from:\n" <>
      Enum.map_join(Experiments.groups(), "\n", &"- `#{&1}`") <>
      "\n\nAsk for one group's options with monty_experiment_options."
  end

  # The config in the words the studio page and the CLI use, then what only a
  # reader of the catalog wants: the objects, the connections, how Monty would
  # parallelise it, and what it reads off the disk.
  defp describe_text(summary) do
    """
    `#{summary.name}` — #{summary.experiment_class.class} (#{summary.source})

    #{facts_text(summary.facts)}
    objects: #{objects_text(summary.objects)}
    connections: #{summary.counts.connections}
    parallel: #{parallel_text(summary.parallel)}

    #{needs_text(summary)}

    #{findings_text(summary.findings)}
    """
  end

  defp facts_text(facts),
    do: Enum.map_join(facts, "\n", fn {label, value} -> "#{label}: #{value}" end)

  # The question before the button: a run refuses while any of these is missing,
  # so the answer belongs here rather than only in a refusal at the end.
  defp needs_text(%{world: "synthetic"}),
    do: "on disk: nothing — this world reads no files."

  defp needs_text(%{needs: []}), do: "on disk: nothing — this setup reads no files."

  defp needs_text(%{needs: needs}) do
    here = Enum.count(needs, & &1.present?)

    "on disk (#{here}/#{length(needs)} here):\n" <>
      Enum.map_join(needs, "\n", fn need ->
        "  - #{presence(need.present?)}: #{need.what} at #{need.path}"
      end)
  end

  defp presence(true), do: "here"
  defp presence(false), do: "missing"

  defp objects_text(%{count: count, names: names}) when is_integer(count) do
    "#{count} named by the config (#{Enum.join(Enum.take(names, 6), ", ")}#{if count > 6, do: ", …"})"
  end

  defp objects_text(%{source: source}), do: "none named by the config — #{source}"

  defp parallel_text(%{num_parallel: count}) when is_integer(count) do
    "the config declares num_parallel #{count} for Monty's own runner; this studio divides " <>
      "the experiment into that many parts — evaluation by episode, training by object"
  end

  defp parallel_text(%{note: note}), do: note

  defp preview_text(preview) do
    "`#{preview.name}` from `#{preview.base}` — #{preview.experiment_class}\n\n" <>
      findings_text(preview.findings) <> "\n\n```yaml\n" <> preview.yaml <> "\n```"
  end

  defp findings_text([]),
    do: "No findings: it composes and every class it names exists here or is planned."

  defp findings_text(findings) do
    Enum.map_join(findings, "\n", fn finding ->
      "- #{finding.level} #{finding.code}: #{finding.message}" <>
        if(finding.where, do: " (#{finding.where})", else: "")
    end)
  end

  defp report_text(report, url) do
    """
    `#{report.experiment}` — #{report.status}, #{steps_text(report)}
    #{url}

    #{summary_text(report.summary)}#{parts_text(report[:parts])}#{log_text(report.log_tail)}
    """
  end

  # A run's steps, said as what they are: `steps_done` is everything its episodes
  # took, and `steps` is the cap on *one* of them, so the `done/limit` form this
  # used read as an overshoot. A finished `base_10simobj_surf_agent` answered
  # "20 780/200 steps": 140 episodes of a surf agent sample several patches per
  # timestep, and no limit was passed.
  defp steps_text(%{steps_done: done, steps: cap}) when is_integer(cap),
    do: "#{done} step(s) taken, #{cap} at most per episode"

  defp steps_text(%{steps_done: done}), do: "#{done} step(s) taken"

  # A run of several parts is one record and one transcript, so the report is the
  # only place an assistant learns the experiment was divided, which part is on
  # which node, and how each one ended. Silent for a run of one part.
  defp parts_text(nil), do: ""
  defp parts_text([]), do: ""

  defp parts_text(parts) do
    done = Enum.count(parts, &Part.ended?(&1.status))

    "\n#{done} of #{List.first(parts).of} parts done:\n" <>
      Enum.map_join(parts, "\n", fn part ->
        where = if is_binary(part.node), do: " on #{part.node}", else: ""

        "- part #{part.part}: #{part.status}#{where}, #{part.steps} step(s)"
      end) <> "\n"
  end

  defp summary_text(nil), do: ""

  defp summary_text(summary) do
    "goals #{Map.get(summary, "goals")} · votes #{Map.get(summary, "votes_used")}/" <>
      "#{Map.get(summary, "votes_sent")} · never updated: #{inspect(Map.get(summary, "never_updated"))}\n"
  end

  defp log_text([]), do: ""

  defp log_text(entries) do
    "\nLast steps:\n" <>
      Enum.map_join(entries, "\n", fn entry ->
        "- step #{entry["step"]}: percepts #{Enum.join(Map.get(entry, "percepts", []), ",")}, " <>
          "#{Map.get(entry, "duration_us")} µs"
      end)
  end

  # The number first, then the shapes, then the page: a reader asking "how many"
  # should not have to count lines to find out.
  defp list_text(index) do
    """
    #{headline(index)}
    #{facets_text(index.facets)}#{experiments_text(index)}
    """
  end

  defp headline(%{total: total, matching: matching}) when total == matching do
    "#{total} experiments."
  end

  defp headline(%{total: total, matching: matching}) do
    "#{matching} of #{total} experiments match."
  end

  defp facets_text([]), do: ""

  # The values, not the labels: a label is for reading, a value is what the
  # caller passes back. Each count is with the *other* filters applied, which is
  # what makes "surf" and "5 learning modules" answerable together — say so,
  # because a count that looks like a total and is not one is worse than none.
  defp facets_text(facets) do
    lines =
      facets
      |> Enum.reject(fn facet -> Enum.all?(facet.values, &(&1.count == 0)) end)
      |> Enum.map_join("\n", fn facet ->
        values =
          facet.values
          |> Enum.reject(&(&1.count == 0))
          |> Enum.sort_by(& &1.count, :desc)
          |> Enum.take(8)
          |> Enum.map_join(" · ", &"#{&1.value} #{&1.count}")

        "#{facet.label}: #{values}"
      end)

    if lines == "",
      do: "",
      else: "\nChoices, each counted with the other filters applied:\n" <> lines <> "\n"
  end

  defp experiments_text(%{experiments: []}), do: "Nothing matches.\n"

  defp experiments_text(page) do
    shown =
      Enum.map_join(page.experiments, "\n", fn experiment ->
        "- `#{experiment.name}` — #{experiment.agent} agent, #{experiment.modules} learning " <>
          "module(s), #{experiment.learning_module}, from #{experiment.model}"
      end)

    more =
      if page.truncated?,
        do: "\n(#{page.total} in total; ask again with `offset: #{page.offset + page.returned}`)",
        else: ""

    "\n#{shown}#{more}\n"
  end

  defp runs_text(%{runs: []}, _base_url),
    do: "No run matches. Ask monty_list_runs with no filter."

  defp runs_text(runs, base_url) do
    counts =
      runs.counts
      |> Enum.sort_by(fn {_state, count} -> -count end)
      |> Enum.map_join(" · ", fn {state, count} -> "#{state} #{count}" end)

    listed =
      Enum.map_join(runs.runs, "\n", fn run ->
        "- `#{run.run_id}` — `#{run.experiment}`, #{run.status}, " <>
          "#{steps_text(run)}\n  #{base_url}/runs/#{run.run_id}"
      end)

    "#{runs.total} run(s) match (#{counts}).\n\n#{listed}"
  end

  defp delete_text(deleted) do
    [head(deleted), refuses(deleted.refused_running), unknown(deleted.unknown_ids)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp head(%{would_delete: [], refused_running: refused} = deleted) when refused == [] do
    if deleted.unknown_ids == [], do: "Nothing to delete: no run matches.", else: ""
  end

  defp head(%{would_delete: []}), do: "Nothing was deleted, and nothing was going to be."

  defp head(deleted) do
    listed = Enum.map_join(deleted.would_delete, "\n", &describe_run/1)

    if deleted.confirm? do
      "Deleted #{deleted.deleted} run(s), with the files they wrote:\n#{listed}"
    else
      "This would delete #{length(deleted.would_delete)} run(s), with the files they wrote:\n" <>
        "#{listed}\n\nNothing was deleted. Call again with `confirm: true` to delete them."
    end
  end

  defp refuses([]), do: ""

  defp refuses(running) do
    "Left alone because they are still running:\n" <>
      Enum.map_join(running, "\n", &describe_run/1)
  end

  defp unknown([]), do: ""
  defp unknown(ids), do: "No such run: #{Enum.join(ids, ", ")}"

  defp describe_run(run) do
    "- `#{run.run_id}` — `#{run.experiment}`, #{run.status}, #{steps_text(run)}"
  end
end
