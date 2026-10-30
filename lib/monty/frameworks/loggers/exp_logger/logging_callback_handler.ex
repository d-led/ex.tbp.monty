defmodule Monty.Frameworks.Loggers.ExpLogger.LoggingCallbackHandler do
  @moduledoc """
  `tbp/monty/frameworks/loggers/exp_logger.py::LoggingCallbackHandler`.

  Calls a list of loggers on an event — `pre_episode`, `post_train`, `close` —
  giving each the event's arguments, the directory the run writes into, and the
  model, exactly as Monty's `call_event` does:

      getattr(logger, event)(logger_args=..., output_dir=..., model=...)

  The Python class mutates its loggers in place; here an event returns the
  handler with each logger's new state, so a caller threads one value and a test
  can look at what a logger was told without a process in between.

  A logger that fails stops the fan-out with its reason. The loggers after it
  were not called, which is why the reason is returned rather than swallowed: a
  run whose statistics were half written is not a run whose statistics can be
  trusted.
  """

  @events [
    :pre_episode,
    :post_episode,
    :pre_epoch,
    :post_epoch,
    :pre_train,
    :post_train,
    :pre_eval,
    :post_eval
  ]

  defstruct loggers: [], model: nil, output_dir: nil

  @typedoc "The loggers to call, the model they are told about, and where to write."
  @type t :: %__MODULE__{loggers: [struct()], model: term(), output_dir: Path.t() | nil}

  @doc """
  A handler for one logger or a list of them.

  Monty wraps a single `BaseMontyLogger` into a list; so does this, so a caller
  that configured one logger and a caller that configured several take the same
  path.
  """
  @spec new(struct() | [struct()], term(), Path.t() | nil) :: t()
  def new(loggers, model, output_dir),
    do: %__MODULE__{loggers: List.wrap(loggers), model: model, output_dir: output_dir}

  @doc "The loggers' names, one per line, as Monty's `logger_list` prints them."
  @spec logger_list(t()) :: String.t()
  def logger_list(%__MODULE__{loggers: loggers}),
    do: Enum.map_join(loggers, "\n", &inspect(&1.__struct__))

  for event <- @events do
    @doc "Calls `#{event}` on every logger."
    @spec unquote(event)(t(), map()) :: {:ok, t()} | {:error, term()}
    def unquote(event)(%__MODULE__{} = handler, logger_args),
      do: call_event(handler, unquote(event), logger_args)
  end

  @doc "Calls `close` on every logger — the event a run ends with."
  @spec close(t(), map()) :: {:ok, t()} | {:error, term()}
  def close(%__MODULE__{} = handler, logger_args), do: call_event(handler, :close, logger_args)

  @doc """
  One event, every logger, in the order they were configured.

  `event` is the logger function to call — `:pre_episode`, `:close` — and each
  logger is dispatched on the module of the struct it is, which is what
  `getattr(logger, event)` does in Python.
  """
  @spec call_event(t(), atom(), map()) :: {:ok, t()} | {:error, term()}
  def call_event(%__MODULE__{} = handler, event, logger_args) do
    handler.loggers
    |> Enum.reduce_while({:ok, []}, fn logger, {:ok, called} ->
      case apply(logger.__struct__, event, [
             logger,
             logger_args,
             handler.output_dir,
             handler.model
           ]) do
        {:ok, updated} -> {:cont, {:ok, [updated | called]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, called} -> {:ok, %{handler | loggers: Enum.reverse(called)}}
      {:error, reason} -> {:error, reason}
    end
  end
end
