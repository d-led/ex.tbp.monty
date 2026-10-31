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
  alias Monty.Studio.{Blueprint, Catalog, Drafts, Finding, Index, Jobs, RunHistory, RunLog, Setup}

  @default_limit 25
  @max_limit 200

  @doc """
  Every experiment that can be opened: how many there are, what shapes they
  come in, and a page of the matching ones.

  The counts lead, because the first question about a catalog of two hundred is
  "how many, and of what" — answering it with two hundred names and their nine
  group choices each is an answer a reader has to count for itself. So the same
  `Monty.Studio.Index` the experiments page is built on answers here too: total,
  the four facets with counts that respect the other filters, and then the
  experiments themselves, paged.

  Word filters the facets do not cover (`:group`/`:option`) narrow the set the
  facets are then counted over, so "of the experiments that use evidence_1lm,
  how many are surface agents" is one call.
  """
  @spec list(keyword()) :: map()
  def list(opts \\ []) do
    all = Catalog.experiments()
    chosen = Enum.filter(all, &chosen?(&1, opts))
    result = chosen |> Index.build() |> Index.filter(facet_params(opts))
    {page, truncated?} = window(result.entries, opts)
    by_name = Map.new(chosen, &{&1.name, &1})

    %{
      total: length(all),
      matching: result.matching,
      returned: length(page),
      offset: opts[:offset] || 0,
      truncated?: truncated?,
      facets: facets(result.facets),
      experiments: Enum.map(page, &brief(&1, by_name[&1.name]))
    }
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
  # `group` and `option` are matched against the catalog Monty ships before the
  # path is built, so neither can carry a separator out of the config tree.
  # sobelow_skip ["Traversal.FileModule"]
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
      # `draft_name/1` answers a sentence, `Drafts.save/1` a file-system reason.
      {:error, reason} -> {:error, inspect(reason)}
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

  @doc """
  The runs one filter matches, newest first, and how many there are of each kind.

  `:state` is a run's own status or `"all"`, `:query` narrows on the
  experiment's name (every word has to match), `:page`/`:limit` walk the list.
  The counts are of every run, not of the page, because "how many failed" is a
  question about the whole record.
  """
  @spec runs(keyword()) :: map()
  def runs(opts \\ []) do
    page =
      RunHistory.search(
        state: opts[:state] || "all",
        text: opts[:query] || "",
        page: opts[:page] || 1,
        per_page: min(opts[:limit] || 10, @max_limit)
      )

    %{
      total: page.total,
      counts: RunHistory.counts(),
      page: page.page,
      pages: page.pages,
      returned: length(page.runs),
      runs: Enum.map(page.runs, &report_of/1)
    }
  end

  @delete_limit 50

  @doc """
  Forgets runs — by id, or everything a filter matches — and only when asked to.

  Two refuses stand between a question and a lost record:

    * **nothing is deleted without `confirm: true`.** The answer says what would
      go, by id and by experiment, which is the review a deletion needs;
    * **a run that has not settled is never deleted.** A running run is the only
      thing that can write down what it did; the tool says so and leaves it.

  And one limit: a filter that matches more than #{@delete_limit} runs is refused
  rather than carried out, because a filter nobody narrowed is not a decision.
  """
  @spec delete_runs(keyword()) :: {:ok, map()} | {:error, String.t()}
  def delete_runs(opts) do
    confirm? = opts[:confirm] == true

    with {:ok, found, unknown} <- delete_targets(opts) do
      settled = Enum.reject(found, &unsettled?/1)
      refused = Enum.filter(found, &unsettled?/1)

      if settled == [] and refused != [] do
        {:error,
         "All #{length(refused)} matching run(s) are still running. A run that has not " <>
           "finished is the only thing that can record what it did, so it is not deleted: " <>
           "wait for it, or stop it, then ask again."}
      else
        deleted = if confirm?, do: RunHistory.delete_ids(Enum.map(settled, & &1.id)), else: 0

        {:ok,
         %{
           confirm?: confirm?,
           deleted: deleted,
           would_delete: Enum.map(settled, &summary_of/1),
           refused_running: Enum.map(refused, &summary_of/1),
           unknown_ids: unknown
         }}
      end
    end
  end

  defp delete_targets(opts) do
    case opts[:run_ids] do
      ids when is_list(ids) and ids != [] ->
        runs = Enum.map(ids, &RunHistory.get/1)
        found = Enum.reject(runs, &is_nil/1)
        unknown = for {id, nil} <- Enum.zip(ids, runs), do: id

        {:ok, found, unknown}

      _no_ids ->
        page =
          RunHistory.search(
            state: opts[:state] || "all",
            text: opts[:query] || "",
            per_page: @delete_limit + 1
          )

        if page.total > @delete_limit do
          {:error,
           "That filter matches #{page.total} runs, more than the #{@delete_limit} a single " <>
             "call will delete. Narrow it (`state`, `query`), or name the runs you mean " <>
             "with `run_ids`."}
        else
          {:ok, page.runs, []}
        end
    end
  end

  defp unsettled?(run), do: run.status == "running"

  defp summary_of(run) do
    %{
      run_id: run.id,
      experiment: run.experiment,
      status: run.status,
      steps_done: length(run.log),
      steps: run.steps,
      started_at: run.started_at
    }
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
      counts: %{
        sensors: length(opened.setup.sensors),
        learning_modules: length(opened.setup.learning_modules),
        connections: length(opened.setup.connections)
      },
      learning_modules: Enum.map(opened.setup.learning_modules, &learning_module/1),
      objects: objects(opened.setup),
      parallel: %{
        num_parallel: num_parallel(opened.config),
        note:
          "Monty's own runner walks that many episodes in parallel; this studio queues " <>
            "runs and steps them one at a time"
      },
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

  # `num_parallel` is Monty's own declaration. Hydra keeps the root's keys at the
  # root of the composed tree and an experiment's override under `experiment`,
  # so both are read; absent from both is "the config never said", which is not
  # the same as one.
  defp num_parallel(config) do
    case config["num_parallel"] || get_in(config, ["experiment", "config", "num_parallel"]) do
      count when is_integer(count) -> count
      _not_declared -> nil
    end
  end

  # Which objects a world starts with. A config that names none is not a config
  # without objects: the interface's sampler places them, or the data path
  # decides, and the answer says which of the two applies.
  defp objects(setup) do
    case setup.environment do
      %{objects: names} when is_list(names) and names != [] ->
        %{count: length(names), names: names, source: "env_init_args"}

      %{data_path: path} when is_binary(path) ->
        %{count: nil, names: [], source: "the object sampler in #{path}"}

      _no_environment ->
        %{count: nil, names: [], source: "unknown"}
    end
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

  defp brief(entry, experiment) do
    %{
      name: entry.name,
      experiment_class: experiment && experiment.experiment_class,
      agent: entry.agent,
      modules: entry.modules,
      learning_module: entry.learning_module,
      model: entry.model,
      groups: entry.groups
    }
  end

  defp facets(facets) do
    Enum.map(facets, fn facet ->
      %{
        key: facet.key,
        label: facet.label,
        values:
          Enum.map(facet.values, fn value ->
            %{value: to_string(value.value), label: value.label, count: value.count}
          end)
      }
    end)
  end

  defp facet_params(opts) do
    %{
      "q" => opts[:query],
      "agent" => opts[:agent],
      "modules" => opts[:modules],
      "learning_module" => opts[:learning_module],
      "model" => opts[:model]
    }
  end

  defp window(entries, opts) do
    limit = min(opts[:limit] || @default_limit, @max_limit)
    offset = opts[:offset] || 0
    page = entries |> Enum.drop(offset) |> Enum.take(limit)

    {page, length(entries) > offset + limit}
  end

  defp chosen?(experiment, opts) do
    matches_group?(experiment, opts[:group], opts[:option])
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
