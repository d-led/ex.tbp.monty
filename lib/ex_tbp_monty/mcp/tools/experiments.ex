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

  @doc "`monty_list_experiments`: how many there are, and what shapes they come in."
  def list(args, _ctx) do
    with {:ok, query} <- Args.optional(args, "query"),
         {:ok, group} <- Args.optional(args, "group"),
         {:ok, option} <- Args.optional(args, "option"),
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

  @doc "`monty_run_experiment`: queue a run, and answer with its link."
  def run(args, ctx) do
    with {:ok, name} <- Args.required(args, "name"),
         {:ok, steps} <- Args.integer(args, "steps", default: 12, min: 1, max: 500),
         {:ok, run} <- Experiments.run(name, steps) do
      url = ctx.base_url <> "/runs/" <> run.run_id

      {:ok,
       %{
         text:
           "Queued #{steps} step(s) of `#{run.experiment}`.\n#{url}\n" <>
             "Run id: `#{run.run_id}`. Watch it at the link, or ask " <>
             "monty_run_report for what it has done.",
         structured: Map.put(run, :url, url)
       }}
    end
  end

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

  defp describe_text(summary) do
    """
    `#{summary.name}` — #{summary.experiment_class.class} (#{summary.source})

    sensors (#{summary.counts.sensors}): #{Enum.map_join(summary.sensors, ", ", & &1.id)}
    learning modules (#{summary.counts.learning_modules}): #{Enum.map_join(summary.learning_modules, ", ", & &1.id)}
    objects: #{objects_text(summary.objects)}
    connections: #{summary.counts.connections} · epochs: train #{summary.epochs.train}, eval #{summary.epochs.eval} · seed: #{inspect(summary.seed)}
    parallel: #{parallel_text(summary.parallel)}
    ported here: #{summary.ported.implemented}/#{summary.ported.total} classes

    #{findings_text(summary.findings)}
    """
  end

  defp objects_text(%{count: count, names: names}) when is_integer(count) do
    "#{count} named by the config (#{Enum.join(Enum.take(names, 6), ", ")}#{if count > 6, do: ", …"})"
  end

  defp objects_text(%{source: source}), do: "none named by the config — #{source}"

  defp parallel_text(%{num_parallel: count}) when is_integer(count) do
    "the config declares num_parallel #{count} for Monty's own runner; this studio queues " <>
      "runs and steps them one at a time"
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
    `#{report.experiment}` — #{report.status}, #{report.steps_done}/#{report.steps} steps
    #{url}

    #{summary_text(report.summary)}#{log_text(report.log_tail)}
    """
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
          "#{run.steps_done}/#{run.steps} steps\n  #{base_url}/runs/#{run.run_id}"
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
    "- `#{run.run_id}` — `#{run.experiment}`, #{run.status}, " <>
      "#{run.steps_done}/#{run.steps} steps"
  end
end
