defmodule Monty.SensorModules.Transforms.OmmatidiaTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.MotorSystemState.AgentState
  alias Monty.Geometry.Rotation
  alias Monty.SensorModules.SensorModule.{Payload, TransformContext}
  alias Monty.SensorModules.Transforms.Ommatidia

  @pose %AgentState{
    position: [0.01, 0.02, 0.003],
    rotation: Rotation.from_quaternion({1.0, 0.0, 0.0, 0.0}) |> elem(1),
    sensors: %{}
  }

  defp step(observation, pose \\ @pose) do
    payload = %Payload{observation: observation}
    context = %TransformContext{agent_state: pose}
    Ommatidia.new() |> Ommatidia.call(context, payload) |> elem(0)
  end

  # One eye reading, in the body's own shape: a row per ommatidium, one value per
  # photoreceptor type.
  defp eye(values),
    do: %{"what" => "ommatidia", "channels" => ["yellow", "pale"], "ommatidia" => values}

  describe "an eye" do
    test "becomes one feature holding every reading of every eye, in the body's order" do
      payload = step(%{"left" => eye([[0.9, 0.0], [0.0, 0.4]]), "right" => eye([[1.0, 0.0]])})

      assert payload.percept.non_morphological_features == %{
               "ommatidia" => [0.9, 0.0, 0.0, 0.4, 1.0, 0.0]
             }
    end

    test "is seen from where the fly stands, because an eye has no depth to put a point at" do
      payload = step(%{"left" => eye([[0.5, 0.0]])})

      assert payload.percept.location == [0.01, 0.02, 0.003]
    end

    test "is on the world and unnamed: background is Monty's id for it" do
      payload = step(%{"left" => eye([[0.5, 0.0]])})

      assert payload.percept.morphological_features["on_object"] == 1.0
      assert payload.percept.semantic_id == 0
      assert payload.percept.process_features_in_lm
    end

    test "carries the body's own orientation as pose vectors, fully defined" do
      turning = %AgentState{
        @pose
        | rotation: Rotation.from_quaternion({0.0, 0.0, 0.0, 1.0}) |> elem(1)
      }

      payload = step(%{"left" => eye([[0.5, 0.0]])}, turning)

      # Half a turn about z: the rows of the identity, reflected through z.
      assert payload.percept.morphological_features["pose_vectors"].value == [
               [-1.0, 0.0, 0.0],
               [0.0, -1.0, 0.0],
               [0.0, 0.0, 1.0]
             ]

      assert payload.percept.morphological_features["pose_fully_defined"] == true
    end
  end

  describe "an observation with no eye" do
    test "passes through with no percept rather than an empty one" do
      payload = step(%{"left" => %{"depth" => [1.0, 2.0]}})

      assert payload.percept == nil
    end
  end

  describe "a percept's sender" do
    test "is the sensor the transform was made for" do
      payload = %Payload{observation: %{"left" => eye([[0.5, 0.0]])}}
      context = %TransformContext{agent_state: @pose}

      {payload, _transform} =
        Ommatidia.new(%{"sensor_module_id" => "fly_eye"}) |> Ommatidia.call(context, payload)

      assert payload.percept.sender_id == "fly_eye"
      assert payload.percept.sender_type == :sm
    end
  end
end
