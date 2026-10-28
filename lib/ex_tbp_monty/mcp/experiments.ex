defmodule ExTbpMonty.Mcp.Experiments do
  @moduledoc """
  Monty's experiments and this studio's runs, asked questions.

  Every answer comes from `Monty.Studio`: `open/2` composes a config and reads it
  back, `preview/2` says what a blueprint would become, `Drafts` writes it and
  `Jobs.Run` queues it. This module exists so the MCP layer never reaches into
  that machinery itself — a tool asks "what is this experiment", not "walk the
  config tree" — and so a change to how a run starts has one caller to keep
  working.

  Nothing here is cached and nothing is assumed: a name that is neither a draft
  nor one of Monty's experiments is an error, not an empty description.
  """

  alias Monty.Config.Source
  alias Monty.Studio
  alias Monty.Studio.{Blueprint, Catalog, Drafts, Finding, Jobs, RunHistory, RunLog, Setup}

  @doc """
  Every experiment that can be opened, filtered by `:query`, `:group`/`:option`.

  `:query` matches the name and the group choices, so "two objects, surf agent"
  finds the experiment that is configured that way rather than the one with
  those words in its name.
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    Catalog.experiments()
    |> Enum.filter(&matching?(&1, opts))
    |> Enum.map(&brief/1)
  end

  @doc "One experiment: what it is made of, and which of that exists here."
  @spec describe(String.t()) :: {:ok, map()} | {:error, String.t()}
  def describe(name) do
    case Studio.open(name) do
      {:ok, opened} ->
        {:ok, summary(opened)}

      {:error, reason} ->
        {:error, "`#{name}` is not an experiment that opens: #{inspect(reason)}"}
    end
  end

  @doc "The groups a config is built from."
  @spec groups() :: [String.t()]
  def groups, do: Catalog.groups()

  @doc "The options one group offers."
  @spec options(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def options(group) do
    case Catalog.options(group) do
      [] -> {:error, "`#{group}` is not a group. Groups: #{Enum.join(Catalog.groups(), ", ")}."}
      options -> {:ok, options}
    end
  end

  @doc """
  One option's own config file, which is where a group's parameters are spelled
  out — `monty/learning_module` chooses the module, the option says what the
  module is told.
  """
  @spec option(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def option(group, option) do
    if group in Catalog.groups() and option in Catalog.options(group) do
      path = Path.join([Source.conf_dir(), group, option <> ".yaml"])

      case File.read(path) do
        {:ok, yaml} -> {:ok, %{group: group, option: option, path: path, yaml: yaml}}
        {:error, reason} -> {:error, "`#{group}/#{option}` cannot be read: #{inspect(reason)}"}
      end
    else
      {:error, "`#{group}/#{option}` is not a config Monty ships. See monty_experiment_options."}
    end
  end

  @doc """
  What a blueprint would become, without writing anything.

  The findings come back whether or not the config composes: "this option does
  not exist" is the answer to a question, and refusing to answer it teaches the
  caller nothing.
  """
  @spec preview(map()) :: {:ok, map()} | {:error, String.t()}
  def preview(attributes) do
    blueprint = Blueprint.new(attributes)
    preview = Studio.preview(blueprint)

    {:ok,
     %{
       name: blueprint.name,
       base: blueprint.base,
       experiment_class: blueprint.experiment_class,
       yaml: preview.yaml,
       findings: findings(preview.findings),
       setup: if(preview.setup, do: brief_setup(preview.setup))
     }}
  end

  @doc "Saves a blueprint as an experiment the studio can open and run."
  @spec create(map()) :: {:ok, map()} | {:error, String.t()}
  def create(attributes) do
    blueprint = Blueprint.new(attributes)

    with :ok <- draft_name(blueprint.name),
         {:ok, path} <- Drafts.save(blueprint) do
      {:ok,
       %{
         name: blueprint.name,
         base: blueprint.base,
         path: path,
         yaml: Blueprint.to_yaml(blueprint)
       }}
    else
      {:error, reason} -> {:error, save_error(reason)}
    end
  end

  @doc """
  Queues a run of an experiment, and answers with the record it just created.

  The run is a job from here, exactly as the page's Run button: it outlives this
  request and it is watched by its id. A setup Monty would refuse is refused
  here too, before anything is queued, because a failed run looks like a run.
  """
  @spec run(String.t(), pos_integer()) :: {:ok, map()} | {:error, String.t()}
  def run(name, steps) when is_integer(steps) and steps > 0 do
    with {:ok, opened} <- Studio.open(name),
         :ok <- runnable(opened),
         {:ok, record} <- record(opened, steps),
         {:ok, _job} <- Jobs.Run.enqueue_run(record) do
      {:ok, %{run_id: record.id, experiment: opened.name, steps: steps, status: record.status}}
    else
      {:error, reason} -> {:error, error_message(reason, name)}
    end
  end

  def run(_name, _steps), do: {:error, "`steps` must be a positive integer."}

  @doc "What a run did, and what it is doing."
  @spec report(String.t()) :: {:ok, map()} | {:error, String.t()}
  def report(run_id) do
    case RunHistory.get(run_id) do
      nil -> {:error, "No run `#{run_id}`. See monty_list_runs."}
      run -> {:ok, report_of(run)}
    end
  end

  @doc "The newest runs, newest first."
  @spec runs(pos_integer()) :: [map()]
  def runs(limit) do
    RunHistory.list(limit: limit)
    |> Enum.map(&report_of/1)
  end

  # -- an experiment ---------------------------------------------------------

  defp summary(opened) do
    %{
      name: opened.name,
      source: opened.source,
      experiment_class: class(opened.setup.experiment_class),
      monty_class: class(opened.setup.monty_class),
      environment: environment(opened.setup.environment),
      motor_system: motor_system(opened.setup.motor_system),
      attention_system: class(opened.setup.attention_system),
      sensors: Enum.map(opened.setup.sensors, &sensor/1),
      learning_modules: Enum.map(opened.setup.learning_modules, &learning_module/1),
      connections: Enum.map(opened.setup.connections, &connection/1),
      epochs: opened.setup.epochs,
      seed: opened.setup.seed,
      monty_args: opened.setup.monty_args,
      supervised_lm_ids: opened.setup.supervised_lm_ids,
      groups: opened.groups,
      ported: Setup.ported(opened.setup),
      findings: findings(opened.setup.findings)
    }
  end

  # A setup read for a one-line answer: enough to say what would run, not the
  # whole of what a page shows.
  defp brief_setup(setup) do
    %{
      sensors: Enum.map(setup.sensors, & &1.id),
      learning_modules: Enum.map(setup.learning_modules, & &1.id),
      epochs: setup.epochs,
      seed: setup.seed,
      ported: Setup.ported(setup),
      findings: findings(setup.findings)
    }
  end

  defp sensor(sensor) do
    %{
      id: sensor.id,
      features: sensor.features,
      module: class(sensor.module)
    }
  end

  defp learning_module(module) do
    %{
      id: module.id,
      module: class(module.module),
      goal_generator: class(module.goal_generator),
      hypotheses_updater: class(module.hypotheses_updater),
      config: module.config
    }
  end

  defp connection(connection) do
    %{
      from: endpoint(connection.from),
      to: endpoint(connection.to),
      kind: connection.kind
    }
  end

  defp endpoint({kind, id}), do: "#{kind}:#{id}"
  defp endpoint(other), do: inspect(other)

  defp class(nil), do: nil

  defp class(description) do
    %{class: description.class, elixir: description.elixir, status: description.status}
  end

  # The environment and the motor system are composed wrappers, not single
  # targets: what they are is a module plus what it was told.
  defp environment(nil), do: nil

  defp environment(environment) do
    %{
      module: class(environment.module),
      interface: class(environment.interface),
      data_path: environment.data_path,
      objects: environment.objects
    }
  end

  defp motor_system(nil), do: nil

  defp motor_system(motor) do
    %{
      module: class(motor.module),
      selector: class(motor.selector),
      policies: Map.new(motor.policies, fn {name, policy} -> {name, class(policy)} end)
    }
  end

  defp findings(findings) do
    Enum.sort_by(findings, &level_rank(&1.level))
    |> Enum.map(fn finding ->
      %{
        level: finding.level,
        code: finding.code,
        message: finding.message,
        where: finding.where
      }
    end)
  end

  # What a caller has to act on first: an error stops Monty, an info does not.
  defp level_rank(:error), do: 0
  defp level_rank(:warning), do: 1
  defp level_rank(:info), do: 2

  defp brief(experiment) do
    %{
      name: experiment.name,
      experiment_class: experiment.experiment_class,
      groups: experiment.groups
    }
  end

  defp matching?(experiment, opts) do
    matches_query?(experiment, opts[:query]) and
      matches_group?(experiment, opts[:group], opts[:option])
  end

  defp matches_query?(_experiment, nil), do: true

  defp matches_query?(experiment, query) do
    haystack =
      [experiment.name, experiment.experiment_class | Map.values(experiment.groups)]
      |> Enum.join(" ")
      |> String.downcase()

    query
    |> String.downcase()
    |> String.split(~r/[^[:alnum:]-]+/u, trim: true)
    |> Enum.all?(&String.contains?(haystack, &1))
  end

  defp matches_group?(_experiment, nil, _option), do: true

  defp matches_group?(experiment, group, option) do
    case Map.fetch(experiment.groups, group) do
      {:ok, chosen} -> is_nil(option) or chosen == option
      :error -> false
    end
  end

  # -- a run -----------------------------------------------------------------

  defp runnable(opened) do
    if Setup.valid?(opened.setup) do
      :ok
    else
      errors =
        opened.setup.findings
        |> Finding.at(:error)
        |> Enum.map_join("; ", & &1.message)

      {:error, "`#{opened.name}` would not run: #{errors}"}
    end
  end

  defp record(opened, steps) do
    RunHistory.start(RunLog.attributes(opened, steps))
  end

  defp report_of(run) do
    %{
      run_id: run.id,
      experiment: run.experiment,
      status: run.status,
      steps: run.steps,
      steps_done: length(run.log),
      started_at: run.started_at,
      finished_at: run.finished_at,
      duration_us: run.duration_us,
      summary: run.summary,
      log_tail: Enum.take(run.log, -5)
    }
  end

  defp error_message(%Ecto.Changeset{} = changeset, name),
    do: "`#{name}` cannot be recorded as a run: #{inspect(changeset.errors)}"

  defp error_message(reason, _name), do: inspect(reason)

  defp save_error(%Ecto.Changeset{} = changeset), do: inspect(changeset.errors)
  defp save_error(reason), do: inspect(reason)

  # A draft is a file named after the experiment, so the name has to be a file
  # name: no separators to climb out of the draft directory with.
  defp draft_name(name) do
    if Regex.match?(~r{\A[a-zA-Z0-9][a-zA-Z0-9_/\-]*\z}, name) do
      :ok
    else
      {:error,
       "`#{name}` is not a usable experiment name: use letters, digits, `_`, `-` and `/`."}
    end
  end
end
