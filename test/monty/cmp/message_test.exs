defmodule Monty.Cmp.MessageTest do
  use ExUnit.Case, async: true

  alias Monty.Cmp.Message
  alias Monty.Geometry.{GazeDirection, OrientationMatrix, SurfacePoseVectors}

  defp pose_vectors do
    SurfacePoseVectors.new([0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0])
  end

  defp on_object_message(overrides \\ %{}) do
    Map.merge(
      %{
        location: [0.1, 0.2, 0.3],
        morphological_features: %{
          "pose_vectors" => pose_vectors(),
          "pose_fully_defined" => true,
          "on_object" => true
        },
        non_morphological_features: %{"hsv" => [0.5, 0.2, 0.9]},
        confidence: 1.0,
        sender_id: "sensor_module_0",
        sender_type: :sm
      },
      overrides
    )
  end

  describe "new/1" do
    test "accepts a sensor percept that carries pose features" do
      assert {:ok, %Message{sender_type: :sm, sender_id: "sensor_module_0"}} =
               Message.new(on_object_message())
    end

    test "accepts a location-only message that does not carry pose features" do
      assert {:ok, %Message{process_features_in_lm: false}} =
               Message.new(%{
                 sender_id: "sensor_module_0",
                 sender_type: :sm,
                 process_features_in_lm: false
               })
    end

    test "refuses features without pose vectors, because a rotated frame is not optional" do
      assert {:error, {:missing_feature, "pose_vectors"}} =
               Message.new(
                 on_object_message(%{morphological_features: %{"pose_fully_defined" => true}})
               )
    end

    test "refuses pose vectors of a type Monty cannot interpret" do
      assert {:error, {:invalid_pose_vectors, pose_vectors}} =
               Message.new(
                 on_object_message(%{
                   morphological_features: %{
                     "pose_vectors" => [[1.0, 0.0, 0.0]],
                     "pose_fully_defined" => true
                   }
                 })
               )

      assert pose_vectors == [[1.0, 0.0, 0.0]]
    end

    test "refuses a confidence outside the unit interval" do
      assert {:error, {:confidence_out_of_range, 1.5}} =
               Message.new(on_object_message(%{confidence: 1.5}))
    end

    test "refuses a location that is not a three-vector" do
      assert {:error, {:invalid_location, [1.0, 2.0]}} =
               Message.new(on_object_message(%{location: [1.0, 2.0]}))
    end

    test "refuses a sender type the protocol does not define" do
      assert {:error, {:invalid_sender_type, :motor, [:sm, :lm]}} =
               Message.new(on_object_message(%{sender_type: :motor}))
    end

    test "refuses a non-boolean pose_fully_defined, which would silently read as true" do
      assert {:error, {:not_a_boolean, "pose_fully_defined", 1}} =
               Message.new(
                 on_object_message(%{
                   morphological_features: %{
                     "pose_vectors" => pose_vectors(),
                     "pose_fully_defined" => 1
                   }
                 })
               )
    end
  end

  describe "from_sensor_module?/1" do
    test "is true for a sensor percept and false for a learning module message" do
      {:ok, sensor} = Message.new(on_object_message())
      {:ok, learning} = Message.new(on_object_message(%{sender_type: :lm}))

      assert Message.from_sensor_module?(sensor)
      refute Message.from_sensor_module?(learning)
    end
  end

  describe "on_object?/1" do
    test "reports what the sensor said" do
      {:ok, off_object} =
        Message.new(
          on_object_message(%{
            morphological_features: %{
              "pose_vectors" => pose_vectors(),
              "pose_fully_defined" => true,
              "on_object" => false
            }
          })
        )

      refute Message.on_object?(off_object)
    end

    test "assumes true when the message says nothing, as Monty does" do
      {:ok, silent} =
        Message.new(
          on_object_message(%{
            morphological_features: %{
              "pose_vectors" => pose_vectors(),
              "pose_fully_defined" => true
            }
          })
        )

      assert Message.on_object?(silent)
    end
  end

  describe "surface_normal/1 and curvature_directions/1" do
    test "read the first row and the two curvature rows of the pose vectors" do
      {:ok, message} = Message.new(on_object_message())

      assert Message.surface_normal(message) == {:ok, [0.0, 0.0, 1.0]}
      assert Message.curvature_directions(message) == {:ok, {[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]}}
    end

    test "say so when the pose is an orientation matrix, which has no surface normal" do
      {:ok, message} =
        Message.new(
          on_object_message(%{
            morphological_features: %{
              "pose_vectors" => %OrientationMatrix{
                value: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
              },
              "pose_fully_defined" => true
            }
          })
        )

      assert Message.surface_normal(message) == {:error, :no_surface_pose_vectors}
    end
  end

  describe "feature/2" do
    test "finds a feature in either bucket" do
      {:ok, message} = Message.new(on_object_message())

      assert Message.feature(message, "hsv") == {:ok, [0.5, 0.2, 0.9]}
      assert Message.feature(message, "on_object") == {:ok, true}
    end

    test "says which feature was missing" do
      {:ok, message} = Message.new(on_object_message())

      assert Message.feature(message, "curvature") == {:error, {:feature_not_found, "curvature"}}
    end
  end

  describe "transform_morphological_features/3" do
    test "moves the location and rotates the pose vectors" do
      {:ok, message} = Message.new(on_object_message())
      quarter_turn = [[0.0, -1.0, 0.0], [1.0, 0.0, 0.0], [0.0, 0.0, 1.0]]

      assert {:ok, transformed} =
               Message.transform_morphological_features(message, [1.0, 0.0, 0.0], quarter_turn)

      assert transformed.location == [1.1, 0.2, 0.3]

      assert {:ok, %SurfacePoseVectors{value: value}} =
               Message.feature(transformed, "pose_vectors")

      # `rotation * pose_vectors`, the way numpy's matrix product reads: the
      # quarter turn maps the surface normal onto +y and the first curvature
      # direction onto -x.
      assert value == [
               [-1.0, 0.0, 0.0],
               [0.0, 0.0, 1.0],
               [0.0, 1.0, 0.0]
             ]
    end

    test "refuses to rotate a gaze direction, which is a target rather than a frame" do
      {:ok, message} =
        Message.new(
          on_object_message(%{
            morphological_features: %{
              "pose_vectors" => %GazeDirection{
                value: [[0.0, 0.0, -1.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
              },
              "pose_fully_defined" => true
            }
          })
        )

      assert Message.transform_morphological_features(message, nil, Monty.Geometry.identity()) ==
               {:error, :gaze_direction_not_transformable}
    end
  end

  describe "set_displacement/3" do
    test "records the displacement and, when given, the point-pair feature" do
      {:ok, message} = Message.new(on_object_message())

      assert %{displacement: displacement} = Message.set_displacement(message, [0.0, 0.1, 0.0])
      assert displacement == %{"displacement" => [0.0, 0.1, 0.0]}

      assert %{displacement: with_ppf} =
               Message.set_displacement(message, [0.0, 0.1, 0.0], 0.42)

      assert with_ppf == %{"displacement" => [0.0, 0.1, 0.0], "ppf" => 0.42}
    end
  end
end
