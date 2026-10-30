defmodule Monty.Frameworks.Loggers.ExpLogger.TestLogger do
  @moduledoc """
  `tbp/monty/frameworks/loggers/exp_logger.py::TestLogger`.

  A logger that writes down which events reached it and, when the run ends,
  writes them to `fake_log.json`. It is how Monty's own tests ask "was
  `post_epoch` called, and before `pre_eval`?" without standing up a logger that
  computes anything.

  The list of events is state threaded back through each call, the way every
  other value here is: `pre_episode/4` returns the logger with the event
  appended.
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

  defstruct handlers: [], log: [], use_parallel_wandb_logging: false

  @typedoc "The events that reached this logger, in the order they arrived."
  @type t :: %__MODULE__{
          handlers: [struct()],
          log: [atom()],
          use_parallel_wandb_logging: boolean()
        }

  @doc "A logger for one handler or a list of them. The log starts empty."
  @spec new(struct() | [struct()]) :: t()
  def new(handlers \\ []), do: %__MODULE__{handlers: List.wrap(handlers)}

  @doc "The events this logger has been told about, most recent last."
  @spec events(t()) :: [atom()]
  def events(%__MODULE__{log: log}), do: Enum.reverse(log)

  for event <- @events do
    @doc "`#{event}`: writes the event down."
    @spec unquote(event)(t(), map(), Path.t() | nil, term()) :: {:ok, t()}
    def unquote(event)(%__MODULE__{} = logger, _logger_args, _output_dir, _model),
      do: {:ok, %{logger | log: [unquote(event) | logger.log]}}
  end

  @doc """
  Writes `fake_log.json` into the run's directory, holding the events in order.

  Monty's `__deepcopy__` returns the logger itself so a test can hold one; there
  is nothing to copy here, because a logger is a value either way.
  """
  # The directory is the run's own results directory, given by the experiment.
  # sobelow_skip ["Traversal.FileModule"]
  @spec close(t(), map(), Path.t() | nil, term()) :: {:ok, t()} | {:error, term()}
  def close(%__MODULE__{} = logger, _logger_args, output_dir, _model) do
    path = Path.join(output_dir, "fake_log.json")

    with :ok <- File.write(path, Jason.encode!(Enum.map(events(logger), &to_string/1))) do
      {:ok, logger}
    end
  end
end
