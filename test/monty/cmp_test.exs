defmodule Monty.CmpTest do
  use ExUnit.Case, async: true

  alias Monty.Cmp
  alias Monty.Cmp.{AttentionRegion, Goal, Message}
  alias Monty.Geometry.SurfacePoseVectors

  defp pose_vectors do
    SurfacePoseVectors.new([0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0])
  end

  defp message(location, overrides \\ %{}) do
    {:ok, message} =
      Message.new(
        Map.merge(
          %{
            location: location,
            morphological_features: %{
              "pose_vectors" => pose_vectors(),
              "pose_fully_defined" => true,
              "on_object" => true
            },
            non_morphological_features: %{"hsv" => [0.5, 0.2, 0.9]},
            sender_id: "sensor_module_0",
            sender_type: :sm
          },
          overrides
        )
      )

    message
  end

  describe "location_mean/1" do
    test "averages the locations that exist" do
      assert Cmp.location_mean([message([0.0, 0.0, 0.0]), message([1.0, 2.0, 4.0])]) ==
               [0.5, 1.0, 2.0]
    end

    test "ignores messages without a location instead of treating them as the origin" do
      {:ok, goal} = Goal.new(%{sender_id: "gsg_0", sender_type: :gsg, location: nil})

      assert Cmp.location_mean([message([2.0, 2.0, 2.0]), goal]) == [2.0, 2.0, 2.0]
    end

    test "is nil when nothing has a location" do
      assert Cmp.location_mean([]) == nil
    end
  end

  describe "encode/1 and decode/1" do
    test "a message survives the round trip with its pose-vector type intact" do
      original = message([0.1, 0.2, 0.3])

      assert {:ok, decoded} = original |> Cmp.encode() |> Cmp.decode()
      assert decoded == original
      assert %SurfacePoseVectors{} = decoded.morphological_features["pose_vectors"]
    end

    test "the wire form names the sender type the way Monty's Python classes do" do
      assert %{"kind" => "message", "sender_type" => "SM"} = Cmp.encode(message([0.0, 0.0, 0.0]))
    end

    test "a percept keeps the semantic id it came with" do
      # Monty's `percept._semantic_id`: carried for logging, so a recorded step
      # can say which object a sensor was on, and read back with everything else.
      original = message([0.0, 0.0, 0.0], %{semantic_id: 3})

      assert %{"semantic_id" => 3} = Cmp.encode(original)
      assert {:ok, %Cmp.Message{semantic_id: 3}} = original |> Cmp.encode() |> Cmp.decode()
    end

    test "a goal survives the round trip, including its tolerances" do
      {:ok, original} =
        Goal.new(%{
          location: [0.0, 0.0, 0.5],
          sender_id: "learning_module_0",
          sender_type: :gsg,
          confidence: 0.75,
          goal_tolerances: %{"location" => 0.015},
          info: %{"target_object" => "mug"}
        })

      assert {:ok, decoded} = original |> Cmp.encode() |> Cmp.decode()
      assert decoded == original
    end

    test "an attention region survives the round trip" do
      original = AttentionRegion.uniform([[0.0, 0.0, 0.0], [1.0, 1.0, 1.0]], 0.5)

      assert {:ok, decoded} = original |> Cmp.encode() |> Cmp.decode()
      assert decoded == original
    end

    test "a payload that would not have been accepted by the constructor is rejected again" do
      payload = %{
        "kind" => "message",
        "location" => nil,
        "morphological_features" => nil,
        "non_morphological_features" => nil,
        "confidence" => 2.0,
        "pass_message" => true,
        "process_features_in_lm" => false,
        "sender_id" => "sensor_module_0",
        "sender_type" => "SM"
      }

      assert Cmp.decode(payload) == {:error, {:confidence_out_of_range, 2.0}}
    end

    test "refuses a kind it does not know" do
      assert Cmp.decode(%{"kind" => "verdict"}) ==
               {:error, {:unknown_payload, %{"kind" => "verdict"}}}
    end
  end
end
