defmodule Monty.Studio.Logging do
  @moduledoc """
  The statistics a run leaves behind, built out of the config that asked for them.

  Monty's experiment constructs its data logger from its own config —
  `experiment.config.logging.monty_data_logger`, one class that pools an
  episode's data, with the handlers it hands that pool to — and this is that
  construction: the config names classes, `Monty.ModuleMap` says which of them
  exist here, and the ones that do are built with the keywords their config gives
  them.

  What this port does not have, it says so about, by name. A handler that is not
  ported is skipped in the notes, and a run whose config names no logger writes
  nothing and says that too. Silence would be the one wrong answer: a run that
  leaves no statistics and a run whose statistics nobody mentioned look the same
  afterwards.

  Episodes are written into the run's own directory rather than into the config's
  `output_dir`. Monty writes every run of an experiment into one directory, which
  is right for a batch of runs and wrong for a studio, where two runs side by side
  would append to one `train_stats.csv`; the run's directory is also the one a
  page can show.
  """

  alias Monty.Studio.{Run, Setup}

  @typedoc """
  What a run will log with, and what it will not.

  `logger` is the data logger itself — a value, as the handlers are — and is
  `nil` when the config names a logger this port does not have. `notes` are for a
  person: one line per class that was skipped, in the order the config named them.
  """
  @type plan :: %{logger: struct() | nil, notes: [String.t()], detailed?: boolean()}

  @doc """
  Builds the logger an experiment's config asks for.

  The classes are resolved through the module map, so a config written for Monty
  needs no Elixir names in it and an unported handler costs a note rather than a
  run.
  """
  @spec open(Setup.t()) :: plan()
  def open(%Setup{logging: logging}) do
    case logger_module(logging.logger) do
      {:ok, module} ->
        {handlers, notes} = handlers(logging.handlers)
        %{logger: module.new(handlers), notes: notes, detailed?: wants_detail?(handlers)}

      {:error, note} ->
        %{logger: nil, notes: [note], detailed?: false}
    end
  end

  @doc """
  Whether a run should ask its modules for the whole hypothesis space.

  Monty's rule, from `init_monty_data_loggers`: the flag the experiment sets on
  every learning module follows from a handler's own `log_level()`, so the
  configured handlers decide it and not a separate switch. A run whose handlers
  want only the BASIC stats keeps none of it, because collecting it is not free.
  """
  @spec detailed?(plan()) :: boolean()
  def detailed?(%{detailed?: detailed?}), do: detailed?

  defp wants_detail?(handlers) when is_list(handlers), do: Enum.any?(handlers, &wants_detail?/1)

  # A wrapper keeps nothing back itself, so the question goes on to the handlers
  # it holds: a `DetailedWandbTableStatsHandler` inside a `WandbWrapper` decides
  # the run's level exactly as it would on its own.
  defp wants_detail?(%{handlers: children} = handler)
       when is_struct(handler) and is_list(children) do
    handler.__struct__.log_level() == :detailed or wants_detail?(children)
  end

  defp wants_detail?(handler), do: handler.__struct__.log_level() == :detailed

  @doc """
  What this plan writes, in one line for a run's log.

  Said at the start of a run rather than at its end, because it is a fact about
  the config: an experiment that logs nothing should be known as one before its
  numbers are missing, not after. A plan with no logger says nothing here — its
  notes already said why.
  """
  @spec describe(plan(), Path.t()) :: [String.t()]
  def describe(%{logger: nil}, _output_dir), do: []

  def describe(%{logger: logger}, output_dir) do
    case Map.get(logger, :handlers, []) do
      [] ->
        ["logging: this config's logger keeps no handlers, so this run writes no statistics"]

      handlers ->
        ["logging: the episode is reported to #{names(handlers)}, into #{output_dir}"]
    end
  end

  defp names(handlers), do: Enum.map_join(handlers, ", ", &inspect(&1.__struct__))

  @doc """
  Reports the episode `run` has just finished, into `output_dir`.

  The order matters and is Monty's: the logger is given the episode *before* the
  model's long-term memory is updated, because a training episode's ground truth
  is rewritten on the way in and an episode logged afterwards would look confused
  about the object it just recognised.

  A handler that fails fails the report, and the logger is not flushed: an
  episode whose statistics were half written is not one whose statistics can be
  trusted, which is the same rule the logging callback follows.
  """
  @spec report(plan(), Run.t(), Path.t()) :: {:ok, plan()} | {:skipped, plan()} | {:error, term()}
  def report(%{logger: nil} = plan, %Run{}, _output_dir), do: {:skipped, plan}

  def report(%{logger: logger} = plan, %Run{} = run, output_dir) do
    case logger.__struct__.post_episode(
           logger,
           Run.logger_args(run),
           output_dir,
           Run.state(run)
         ) do
      {:ok, logger} -> {:ok, %{plan | logger: logger}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp logger_module(nil) do
    {:error, "logging: this experiment names no data logger, so this run writes no statistics"}
  end

  defp logger_module(description) do
    case described_module(description) do
      {:ok, module} -> {:ok, module}
      {:error, why} -> {:error, "logging: #{why}, so this run writes no statistics"}
    end
  end

  defp handlers(handlers) do
    {built, notes} =
      Enum.reduce(handlers, {[], []}, fn handler, {built, notes} ->
        case build(handler) do
          {:ok, struct, nested} -> {[struct | built], notes ++ nested}
          {:error, refused} -> {built, notes ++ refused}
        end
      end)

    {Enum.reverse(built), notes}
  end

  # A handler is built from the keywords its config gives it, and those keywords
  # can name classes themselves — a `WandbWrapper` is given its `wandb_handlers`
  # — so building one is the same job one level down, with the same rule: a class
  # this port does not have is skipped and named rather than handed to a handler
  # as `nil`.
  defp build(%{module: nil}) do
    {:error, ["logging: a handler in this config names no class; skipped"]}
  end

  defp build(%{module: description, config: config}) do
    case described_module(description) do
      {:ok, module} ->
        {arguments, notes} = arguments(config)

        # A handler that asks for nested handlers and gets none has nothing to
        # report: a `WandbWrapper` with no handlers would open a run and commit
        # empty steps. Saying so is the same rule as for the classes themselves.
        if emptied?(config, arguments) do
          {:error,
           notes ++ ["logging: #{cite(description)} wraps no handler this port has; skipped"]}
        else
          {:ok, module.from_config(arguments), notes}
        end

      {:error, why} ->
        {:error, ["logging: #{why}; skipped"]}
    end
  end

  defp emptied?(config, arguments) do
    Enum.any?(config, fn {key, value} -> asked?(value) and Map.get(arguments, key) == [] end)
  end

  defp asked?(list) when is_list(list), do: Enum.any?(list, &match?(%{module: _}, &1))
  defp asked?(_not_a_list), do: false

  defp arguments(config) do
    {pairs, notes} =
      Enum.map_reduce(config, [], fn {key, value}, notes ->
        {value, nested} = argument(value)
        {{key, value}, notes ++ nested}
      end)

    {Map.new(pairs), notes}
  end

  # Only a described handler, and a list of them, nest. A plain keyword passes
  # through untouched: a string that happens to name a class is a parameter, not
  # a target.
  defp argument(%{module: _} = entry) do
    case build(entry) do
      {:ok, struct, notes} -> {struct, notes}
      {:error, refused} -> {nil, refused}
    end
  end

  defp argument(list) when is_list(list) do
    {values, notes} =
      Enum.map_reduce(list, [], fn value, notes ->
        {value, nested} = argument(value)
        {value, notes ++ nested}
      end)

    {Enum.reject(values, &is_nil/1), notes}
  end

  defp argument(value), do: {value, []}

  # The map says whether a class is ported; the code loader says whether the
  # module it points at is there. Asking both keeps a stale map from becoming a
  # crash in the middle of a run, and a note instead.
  defp described_module(%{status: :implemented, elixir: elixir}) do
    module = Module.concat([elixir])

    if Code.ensure_loaded?(module),
      do: {:ok, module},
      else: {:error, "#{elixir} is mapped as implemented but is not loaded"}
  end

  defp described_module(%{status: :excluded} = description) do
    {:error, "#{cite(description)} is excluded from this port"}
  end

  defp described_module(%{status: :planned} = description) do
    {:error, "#{cite(description)} is not ported yet"}
  end

  defp described_module(description) do
    {:error, "#{cite(description)} is not a class the module map knows"}
  end

  # How this project cites a class it does not have: the Python file and the
  # class, as the map and the docs write them.
  defp cite(%{package: package, python: python} = description),
    do: "#{package}/#{python}::#{description.class}"

  defp cite(%{python: python} = description), do: "#{python}::#{description.class}"
end
