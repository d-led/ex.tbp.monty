defmodule Monty.Test.Messages do
  @moduledoc "Helpers for building valid CMP payloads in tests."

  alias Monty.Cmp.Message
  alias Monty.Geometry.SurfacePoseVectors

  @doc "A sensor percept at `location`."
  def percept(overrides \\ %{}) do
    {:ok, message} =
      Message.new(
        Map.merge(
          %{
            location: [0.0, 0.0, 0.0],
            morphological_features: %{
              "pose_vectors" =>
                SurfacePoseVectors.new([0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]),
              "pose_fully_defined" => true,
              "on_object" => true
            },
            non_morphological_features: %{},
            sender_id: "sensor_module",
            sender_type: :sm
          },
          overrides
        )
      )

    message
  end

  @doc "A learning module's top-down output."
  def output(overrides \\ %{}) do
    percept(
      Map.merge(%{location: nil, sender_id: "learning_module", sender_type: :lm}, overrides)
    )
  end
end
