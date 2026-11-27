defmodule Monty.Telemetry.TelemetryTest do
  @moduledoc """
  Translations of Monty's `tests/unit/telemetry/telemetry_test.py`.

  Monty's telemetry rides on `logging`: a `TelemetrySchema` is passed as a
  logger's message, a `logging.Handler` receives it as `record.msg`, and a
  formatter turns the record into JSON. There is no `logging` here, so the same
  three facts are kept in the port's own shapes — an event struct, a record map
  (`Monty.Telemetry.Publishers.TelemetryPublisher.record/3`), and a collector
  that plays the part of the handler the case installs.

  Hypothesis' generated kinds and extras become fixed lists over the same
  ranges. Monty's `TypeError` for a message that is not a schema is the port's
  `ArgumentError` with the same sentence: what a caller can act on is the
  refusal and its words, not the class of the exception.
  """

  use ExUnit.Case, async: false

  alias Monty.Telemetry.Collector
  alias Monty.Telemetry.Formatters.JsonFormatter
  alias Monty.Telemetry.Publishers.TelemetryPublisher
  alias Monty.Telemetry.Schemas.{TelemetryEvent, TelemetrySchema}
  alias Monty.Telemetry.Telemeter

  describe "an event's kind" do
    # test_kind_defaults_to_class_name_when_empty
    test "is its schema's name when the call site gave none" do
      event = TelemetryEvent.new("")

      assert TelemetrySchema.kind(event) == "TelemetryEvent"
      assert TelemetrySchema.to_string(event) == TelemetrySchema.kind(event)
    end

    # test_kind_is_preserved_when_non_empty
    test "and is kept as it was written" do
      for kind <- ["DebugEvent", "A", "a kind with spaces", "üñïcode"] do
        event = TelemetryEvent.new(kind)

        assert TelemetrySchema.kind(event) == kind
        assert TelemetrySchema.to_string(event) == kind
      end
    end

    # test_custom_fields_override_kind
    test "and the call site's own fields travel beside it, not over it" do
      extras = %{"your_key" => "your_value", "count" => 3, "empty" => nil}

      event = TelemetryEvent.new("CustomEvent", extras)

      assert TelemetrySchema.kind(event) == "CustomEvent"
      assert event.fields == extras

      # A field named `kind` is the event's own, as a pydantic field is its
      # validator's.
      shadowed = TelemetryEvent.new("CustomEvent", %{"kind" => "not the kind"})

      assert TelemetrySchema.kind(shadowed) == "CustomEvent"
      assert TelemetryEvent.to_map(shadowed)["kind"] == "CustomEvent"
    end
  end

  describe "a record as JSON" do
    # test_format_logrecord_to_expected_json
    test "is where it came from, at which level, and the event's fields" do
      for {level, name} <- [debug: "DEBUG", info: "INFO", warning: "WARNING"] do
        event = TelemetryEvent.new("SomeEvent", %{"count" => 1})

        record = record(level, event)

        expected = %{
          "level" => name,
          "name" => "telemetry.monty.frameworks",
          "funcName" => "step/2",
          "lineno" => 42
        }

        assert record |> JsonFormatter.format() |> Jason.decode!() ==
                 Map.merge(expected, TelemetryEvent.to_map(event))
      end
    end

    # test_raise_typeerror_if_msg_is_not_telemetry_schema
    test "is refused when the message is not a telemetry schema" do
      assert_raise ArgumentError, "This formatter only accepts telemetry schemas", fn ->
        JsonFormatter.format(record(:info, "I am not a schema"))
      end
    end
  end

  describe "asking for a publisher" do
    # test_returns_publisher_with_telemetry_prefixed_name
    test "gives one named for the module, under the telemetry prefix" do
      telemeter = Telemeter.get_telemeter("monty.frameworks.models.graph_matching")

      assert %TelemetryPublisher{} = telemeter
      assert telemeter.name == "telemetry.monty.frameworks.models.graph_matching"
      refute TelemetryPublisher.propagate?(telemeter)
    end

    # test_does_not_duplicate_telemetry_prefix
    test "and does not add a prefix that is already there" do
      prefixed = Telemeter.get_telemeter("telemetry.monty.frameworks")

      assert %TelemetryPublisher{} = prefixed
      assert prefixed.name == "telemetry.monty.frameworks"

      # The same name answers an equal publisher either way it is asked.
      assert prefixed == Telemeter.get_telemeter("monty.frameworks")
      refute TelemetryPublisher.propagate?(prefixed)
    end
  end

  # test_logrecord_msg_is_telemetry_event
  test "what a publisher emits is the event, at the level it was asked for" do
    start_supervised!({Collector, []})
    telemeter = Telemeter.get_telemeter("test")

    debug_event = TelemetryEvent.new("DebugEvent")
    info_event = TelemetryEvent.new("InfoEvent")

    TelemetryPublisher.emit(telemeter, :debug, debug_event)
    TelemetryPublisher.emit(telemeter, :info, info_event)

    assert [first, second] = Collector.events()
    assert first.level == :debug
    assert first.msg == debug_event
    assert second.level == :info
    assert second.msg == info_event
  end

  # A record as the publisher would make one. Its message is whatever the case
  # is about — an event, or the string the formatter has to refuse.
  defp record(level, msg) do
    %{level: level, name: "telemetry.monty.frameworks", func_name: "step/2", lineno: 42, msg: msg}
  end
end
