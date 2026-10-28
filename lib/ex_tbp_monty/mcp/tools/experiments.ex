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

  @doc "`monty_list_experiments`: the experiments that can be opened."
  def list(args, _ctx) do
    with {:ok, query} <- Args.optional(args, "query"),
         {:ok, group} <- Args.optional(args, "group"),
         {:ok, option} <- Args.optional(args, "option") do
      experiments = Experiments.list(query: query, group: group, option: option)

      {:ok,
       %{
         text: list_text(experiments),
         structured: %{count: length(experiments), experiments: experiments}
       }}
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

  @doc "`monty_list_runs`: the newest runs."
  def list_runs(args, ctx) do
    with {:ok, limit} <- Args.integer(args, "limit", default: 10, min: 1, max: 50) do
      runs = Experiments.runs(limit)

      {:ok,
       %{
         text: runs_text(runs, ctx.base_url),
         structured: %{count: length(runs), runs: runs}
       }}
    end
  end

  # -- text ------------------------------------------------------------------

  defp list_text(experiments) do
    if experiments == [] do
      "No experiment matches. Call monty_list_experiments with no arguments to see them all."
    else
      Enum.map_join(experiments, "\n", fn experiment ->
        "- `#{experiment.name}` — #{experiment.experiment_class}"
      end)
    end
  end

  defp groups_text do
    "The groups a config is built from:\n" <>
      Enum.map_join(Experiments.groups(), "\n", &"- `#{&1}`") <>
      "\n\nAsk for one group's options with monty_experiment_options."
  end

  defp describe_text(summary) do
    """
    `#{summary.name}` — #{summary.experiment_class.class} (#{summary.source})

    sensors: #{Enum.map_join(summary.sensors, ", ", & &1.id)}
    learning modules: #{Enum.map_join(summary.learning_modules, ", ", & &1.id)}
    connections: #{length(summary.connections)} · epochs: train #{summary.epochs.train}, eval #{summary.epochs.eval} · seed: #{inspect(summary.seed)}
    ported here: #{summary.ported.implemented}/#{summary.ported.total} classes

    #{findings_text(summary.findings)}
    """
  end

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

  defp runs_text([], _base_url), do: "No runs yet."

  defp runs_text(runs, base_url) do
    Enum.map_join(runs, "\n", fn run ->
      "- `#{run.run_id}` — `#{run.experiment}`, #{run.status}, #{run.steps_done}/#{run.steps} steps\n" <>
        "  #{base_url}/runs/#{run.run_id}"
    end)
  end
end
