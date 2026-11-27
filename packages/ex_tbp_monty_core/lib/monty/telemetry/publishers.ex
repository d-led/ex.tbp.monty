defmodule Monty.Telemetry.Publishers do
  @moduledoc """
  Where a run's telemetry goes.

  Mirrors `tbp/monty/telemetry/publishers.py`, whose one class is
  `...Publishers.TelemetryPublisher`: a publisher named for the module that emits
  through it, which keeps its events to itself rather than passing them up to a
  root logger.

  A publisher here writes a record and hands it to
  `Monty.Telemetry.Collector`, this port's own way of reading a run's stream —
  Monty's dashboard listens on a ZMQ socket, and the studio reads the collector
  (`docs/monty-differences.md`).
  """
end
