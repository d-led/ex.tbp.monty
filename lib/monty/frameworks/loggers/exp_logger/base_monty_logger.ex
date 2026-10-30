defmodule Monty.Frameworks.Loggers.ExpLogger.BaseMontyLogger do
  @moduledoc """
  `tbp/monty/frameworks/loggers/exp_logger.py::BaseMontyLogger`.

  A logger that holds handlers and does nothing else: every event is a no-op and
  `close` closes the handlers. It is the shape a concrete logger fills in —
  `GraphMatchingLoggers.BasicGraphMatchingLogger` accumulates stats before it
  reports them, `WandbHandlers` sends them, `TestLogger` writes down that the
  event happened.

  Each event returns the logger, because the events exist to carry state from one
  end of a run to the other; here that state is the value returned rather than a
  field mutated in place.
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

  defstruct handlers: [], use_parallel_wandb_logging: false

  @typedoc "The handlers this logger reports through."
  @type t :: %__MODULE__{handlers: [struct()], use_parallel_wandb_logging: boolean()}

  @doc "A logger for one handler or a list of them."
  @spec new(struct() | [struct()]) :: t()
  def new(handlers \\ []), do: %__MODULE__{handlers: List.wrap(handlers)}

  @doc "Nothing is buffered, so nothing has to be sent."
  @spec flush(t()) :: {:ok, t()}
  def flush(%__MODULE__{} = logger), do: {:ok, logger}

  for event <- @events do
    @doc "`#{event}`: a logger with no statistics of its own has nothing to do."
    @spec unquote(event)(t(), map(), Path.t() | nil, term()) :: {:ok, t()}
    def unquote(event)(%__MODULE__{} = logger, _logger_args, _output_dir, _model),
      do: {:ok, logger}
  end

  @doc """
  Closes every handler.

  A handler that is already closed is closed again rather than guarded against:
  closing twice is what a run that was stopped twice does, and none of the
  handlers here holds a resource that minds.
  """
  @spec close(t(), map(), Path.t() | nil, term()) :: {:ok, t()}
  def close(%__MODULE__{handlers: handlers} = logger, _logger_args, _output_dir, _model) do
    Enum.each(handlers, fn handler -> handler.__struct__.close(handler) end)
    {:ok, logger}
  end
end
