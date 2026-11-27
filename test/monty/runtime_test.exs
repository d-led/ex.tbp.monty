defmodule Monty.RuntimeTest do
  @moduledoc """
  Translations of Monty's `tests/unit/runtime_test.py`.

  Monty builds its two messages with a helper that takes the sender's type and
  the flag; the same two are built here from `Message.new`. The case is the
  whole of Monty's file: a learning module's own percept never decides whether
  a step was a location-only one, because the question is what the *sensors*
  brought.
  """

  use ExUnit.Case, async: true

  alias Monty.Cmp.Message
  alias Monty.Geometry.SurfacePoseVectors
  alias Monty.Runtime

  # test_ignores_lm_features
  test "a step is location-only unless a sensor module brought features to match" do
    sensor_without_features = message(:sm, false)
    sensor_with_features = message(:sm, true)
    learning_module_with_features = message(:lm, true)

    # A learning module's percept says nothing about this step's sensors.
    assert Runtime.location_only_step?([sensor_without_features, learning_module_with_features])

    refute Runtime.location_only_step?([sensor_with_features])
  end

  defp message(sender_type, process_features_in_lm?) do
    {:ok, message} =
      Message.new(
        location: [0.0, 0.0, 0.0],
        morphological_features: %{
          "pose_vectors" =>
            SurfacePoseVectors.new([0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]),
          "pose_fully_defined" => true
        },
        non_morphological_features: %{},
        confidence: 1.0,
        pass_message: true,
        process_features_in_lm: process_features_in_lm?,
        sender_id: "#{sender_type}_0",
        sender_type: sender_type
      )

    message
  end
end
