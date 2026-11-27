defmodule Monty.Telemetry.Schemas do
  @moduledoc """
  What a telemetry event is, and the version it speaks.

  Mirrors `tbp/monty/telemetry/schemas.py`, a pydantic module holding
  `TelemetrySchema` and `TelemetryEvent`:

    * `...Schemas.TelemetrySchema` is the base every event is one of: a `kind`
      that names the event, a `VERSION` the fields are read with, and the rule
      that an empty kind is the schema's own name;
    * `...Schemas.TelemetryEvent` is the one Monty's code emits: the base with
      room for whatever a call site wants to say — pydantic's
      `extra="allow"`, which here is a `fields` map.

  ## Why a struct rather than a pydantic model

  pydantic validates and coerces; an Elixir struct is the type. The port keeps
  the part a reader acts on — the `kind`, the version, and the payload as it was
  written — and drops the coercion, because a schema written from a call site is
  already the shape that call site meant. `to_map/1` is `model_dump(mode="json")`
  and nothing else.

  ## Reading the stream

  A run's events are emitted through `Monty.Telemetry.Publishers.TelemetryPublisher`
  and can be collected by `Monty.Telemetry.Collector`, which is this port's own:
  Monty's dashboard subscribes to a ZMQ publisher, and the studio reads the
  collector instead (`docs/monty-differences.md`).
  """
end
