defmodule Monty.Telemetry.Telemeter do
  @moduledoc """
  The one way a module asks for a telemetry publisher.

  Mirrors `tbp/monty/telemetry/telemeter.py::getTelemeter`, which is `logging`'s
  `getLogger` reshaped: a name is prefixed with `telemetry.` and the logger it
  answers is a `TelemetryPublisher`.

  Monty's factory hands back the same logger for a name because loggers are
  global; a publisher here is a value, so `get_telemeter/1` answers an equal one
  every time — the name, and nothing that changes between calls.
  """

  alias Monty.Telemetry.Publishers.TelemetryPublisher

  @doc """
  The publisher for `name`.

  Monty's `getTelemeter(__name__)`: the module that emits says who it is, and the
  prefix is not its business.
  """
  @spec get_telemeter(String.t(), keyword()) :: TelemetryPublisher.t()
  def get_telemeter(name, options \\ []) do
    TelemetryPublisher.new(name, options)
  end
end
