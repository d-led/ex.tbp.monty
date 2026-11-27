defmodule Monty.Telemetry.Formatters do
  @moduledoc """
  How a telemetry record is written out.

  Mirrors `tbp/monty/telemetry/formatters.py`, whose one class is
  `...Formatters.JsonFormatter`: a log record carrying a telemetry schema as its
  message becomes one JSON object — where it came from, at which level, and the
  event's own fields beside those.
  """
end
