defmodule Monty.Test.ClosingHandler do
  @moduledoc """
  A handler that writes down that it was closed.

  `BaseMontyLogger.close/4` hands every handler its own close, and the handlers
  this port has write nothing when closed, so the only way to see that it happens
  is a handler that says so. It runs in the caller's process, which is the test.
  """

  @behaviour Monty.Frameworks.Loggers.MontyHandlers.MontyHandler

  defstruct []

  @impl true
  def log_level, do: :basic

  @impl true
  def report_episode(_handler, _data, _output_dir, _episode, _mode, _episodes_to_total),
    do: {:ok, %__MODULE__{}}

  @impl true
  def close(%__MODULE__{}) do
    send(self(), {:closed, __MODULE__})
    :ok
  end

  @doc "`MontyHandler.from_config/1`: this handler takes no keywords."
  @impl true
  def from_config(_config), do: %__MODULE__{}
end
