defmodule Monty.Test.FailingLogger do
  @moduledoc """
  A logger whose every event fails.

  The loggers this port has all succeed, so a fan-out that stops at a failure —
  instead of quietly reporting the rest and leaving a run's statistics half
  written — can only be seen with a logger that fails.
  """

  defstruct handlers: [], reason: :failed

  def new(reason \\ :failed), do: %__MODULE__{reason: reason}

  for event <- [
        :pre_episode,
        :post_episode,
        :pre_epoch,
        :post_epoch,
        :pre_train,
        :post_train,
        :pre_eval,
        :post_eval,
        :close
      ] do
    def unquote(event)(%__MODULE__{reason: reason}, _logger_args, _output_dir, _model),
      do: {:error, reason}
  end
end
