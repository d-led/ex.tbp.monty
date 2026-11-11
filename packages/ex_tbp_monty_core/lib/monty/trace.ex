defmodule Monty.Trace do
  @moduledoc ~S"""
  The experiment's own words, which are not a log level's to print.

  Monty's Python says things like

      logger.info(f"{self.learning_module_id} did not recognize an object yet.")

  on every step of every episode, and this port says them in the same places. A
  run of twenty thousand steps says that twenty thousand times. It is not
  `:info` — nobody reading a console needs it to know a run is going — and it is
  not `:debug` either, because nobody is debugging a step while it prints. So it
  is a level of its own, below `:debug`, called `trace`, and off by default:

      Monty.Trace.trace("no match found in time, not updating memory")

      Monty.Trace.trace(fn ->
        "possible poses after matching for #{graph_id}: #{inspect(poses)}"
      end)

  The function form is for the lines that cost something to build. Said the
  other way round, a run inspected every hypothesis of every step of every
  episode and threw the string away; here a line that is not wanted costs a
  comparison.

  What keeps its own level is everything that is not the experiment talking: a
  run starting, finishing or failing, a page opened, a connection opened and
  closed (`:info`); a write that could not happen (`:warning`); a run that could
  not start at all (`:error`).

  Turning it on: `MONTY_TRACE=1 mix phx.server`, or
  `config :ex_tbp_monty_core, experiment_trace: true`. The lines are logged at
  `:debug`, so the console's level has to allow that as well — `:debug` is the
  default in development, and the release leaves it at `:info`.
  """

  require Logger

  @doc """
  Says `message` when the experiment's trace is asked for.

  `message` may be a function, and should be one when building it costs
  anything: a message that is not wanted is then a comparison, and nothing else.
  """
  @spec trace(String.t() | (() -> String.t())) :: :ok
  def trace(message) when is_binary(message), do: trace(fn -> message end)

  def trace(message) when is_function(message, 0) do
    if enabled?(), do: Logger.debug(message, trace: true)
    :ok
  end

  @doc """
  Whether the experiment is talking.

  Read once per line, so it is cheap; a value that is not a boolean is tolerated
  because `MONTY_TRACE=1` is how a shell says yes.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:ex_tbp_monty_core, :experiment_trace, false) in [true, "true", "1"]
  end
end
