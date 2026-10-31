defmodule Monty.Frameworks.Loggers.MontyHandlers.MontyHandler do
  @moduledoc """
  `tbp/monty/frameworks/loggers/monty_handlers.py::MontyHandler`.

  The contract a handler meets: it is handed an episode's logs at one level, it
  reports them, and it is closed at the end of the run.

  Monty writes the events with `**kwargs`:

      report_episode(self, data, output_dir, episode, mode=ExperimentMode.TRAIN,
                     **kwargs)   # plus f"{mode}_episodes_to_total"

  which an Elixir function cannot mirror, so the two variable parts are named:
  `report_episode/5` takes the log dictionary, the directory, the local episode
  and the mode, and `episodes_to_total` — Monty's `f"{mode}_episodes_to_total"`,
  the map from local episode to the run's running episode id — is the fifth.

  Handlers are values: a report returns the handler with its new state, so a
  logger can hold one and thread it without a process in between.
  """

  alias Monty.Frameworks.Experiments.Mode.ExperimentMode

  @typedoc """
  Monty's log dictionary, which the handlers filter out of by level.

  `%{"BASIC" => %{"train_stats" => %{0 => %{"LM_0" => stats}}}}`, with
  `"DETAILED"` beside `"BASIC"` once a detailed logger has filled it.
  """
  @type logs :: %{optional(String.t()) => map()}

  @doc "Reports one episode's logs, returning the handler with what it recorded."
  @callback report_episode(
              handler :: struct(),
              data :: logs(),
              output_dir :: Path.t(),
              episode :: non_neg_integer(),
              mode :: ExperimentMode.t(),
              episodes_to_total :: %{optional(non_neg_integer()) => integer()}
            ) :: {:ok, struct()} | {:error, term()}

  @doc "Closes whatever the handler holds open. Most hold nothing."
  @callback close(handler :: struct()) :: :ok

  @doc """
  Builds a handler from the keywords its config gives it.

  Monty constructs a handler as `handler_class(**kwargs)`, where the keywords
  are whatever the config wrote under the `_target_`. This is that call with the
  config's map in place of the `**`: a handler reads the keys it knows and
  ignores the ones it does not, exactly as `**kwargs` would.
  """
  @callback from_config(config :: map()) :: struct()

  @doc """
  The level this handler filters out of the logs.

  A handler that wants the BASIC stats says `:basic`; one that wants the
  detailed pool says `:detailed`. Monty returns the string `"BASIC"`/`"DETAILED"`;
  here the level is an atom and only the log dictionary keeps Monty's strings.
  """
  @callback log_level() :: :basic | :detailed
end
