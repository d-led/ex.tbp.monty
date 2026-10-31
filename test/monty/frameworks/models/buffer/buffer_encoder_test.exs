defmodule Monty.Frameworks.Models.Buffer.BufferEncoderTest do
  use ExUnit.Case, async: false

  alias Monty.Cmp.{AttentionRegion, Goal, Message}
  alias Monty.Frameworks.Models.Buffer.BufferEncoder
  alias Monty.Geometry.SurfacePoseVectors

  # Translated from Monty's `buffer_test.py::BufferEncoderTest`. The registry is
  # process-global (an encoder is a definition, not a value), so these tests run
  # one at a time and clean up after themselves.
  setup do
    on_exit(fn -> Application.delete_env(:ex_tbp_monty, :buffer_encoders_extra) end)
  end

  defmodule Thing do
    defstruct [:value]
  end

  defmodule SubThing do
    defstruct [:value]
  end

  defmodule ThingEncoder do
    def encode(%Thing{value: value}), do: %{"kind" => "thing", "value" => value}
  end

  defp message do
    {:ok, message} =
      Message.new(%{
        sender_id: "SM_0",
        sender_type: :sm,
        location: [1.0, 2.0, 3.0],
        morphological_features: %{
          "pose_vectors" => SurfacePoseVectors.new([0, 0, 1], [1, 0, 0], [0, 1, 0]),
          "pose_fully_defined" => true
        }
      })

    message
  end

  describe "the registry" do
    test "a registered function encodes its type" do
      :ok = BufferEncoder.register(Thing, fn %Thing{value: value} -> %{"value" => value} end)

      assert BufferEncoder.encode(%Thing{value: 7}) == %{"value" => 7}
    end

    test "a registered module encodes its type" do
      :ok = BufferEncoder.register(Thing, ThingEncoder)

      assert BufferEncoder.encode(%Thing{value: 7}) == %{"kind" => "thing", "value" => 7}
    end

    test "something that is neither a function nor an encoder is refused" do
      assert_raise ArgumentError, ~r/invalid encoder/, fn ->
        BufferEncoder.register(Thing, :not_an_encoder)
      end
    end

    test "unregistering leaves the default encoding in place" do
      :ok = BufferEncoder.register(Thing, fun = fn %Thing{} -> %{"encoded" => true} end)
      assert is_function(fun)
      assert BufferEncoder.encode(%Thing{value: 7}) == %{"encoded" => true}

      :ok = BufferEncoder.unregister(Thing)

      # Without an encoder of its own, a struct is an error rather than a string.
      assert_raise ArgumentError, ~r/no encoder for/, fn ->
        BufferEncoder.encode(%Thing{value: 7})
      end
    end

    test "a type's own encoder wins over anything registered for another" do
      :ok = BufferEncoder.register(Thing, ThingEncoder)
      :ok = BufferEncoder.register(SubThing, fn %SubThing{} -> "sub" end)

      assert BufferEncoder.encode(%Thing{value: 1}) == %{"kind" => "thing", "value" => 1}
      assert BufferEncoder.encode(%SubThing{value: 1}) == "sub"
    end

    test "an encoder is applied once, and its result is what comes out" do
      :ok = BufferEncoder.register(Thing, fn %Thing{value: value} -> %{"value" => value} end)

      # Nested inside a list or a map, a registered type still finds its encoder.
      assert BufferEncoder.encode(%{things: [%Thing{value: 1}]}) == %{things: [%{"value" => 1}]}
    end
  end

  describe "the default encoding" do
    test "passes through what JSON already has" do
      assert BufferEncoder.encode(1) == 1
      assert BufferEncoder.encode(1.5) == 1.5
      assert BufferEncoder.encode("text") == "text"
      assert BufferEncoder.encode(true) == true
      assert BufferEncoder.encode(nil) == nil
    end

    test "turns atoms into their names and walks lists and maps" do
      assert BufferEncoder.encode(:sm) == "sm"
      assert BufferEncoder.encode([1, [2, :three]]) == [1, [2, "three"]]
      assert BufferEncoder.encode(%{a: [1, :b]}) == %{a: [1, "b"]}
    end

    test "encodes a CMP message as its wire form" do
      encoded = BufferEncoder.encode(message())

      assert encoded["kind"] == "message"
      assert encoded["sender_id"] == "SM_0"
      assert encoded["sender_type"] == "SM"
      assert encoded["location"] == [1.0, 2.0, 3.0]
    end

    test "encodes geometry as its matrix, which is what a reader expects" do
      pose = SurfacePoseVectors.new([0, 0, 1], [1, 0, 0], [0, 1, 0])

      orientation = %Monty.Geometry.OrientationMatrix{
        value: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
      }

      gaze = %Monty.Geometry.GazeDirection{
        value: [[0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]
      }

      assert BufferEncoder.encode(pose) == [[0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]

      assert BufferEncoder.encode(orientation) == [
               [1.0, 0.0, 0.0],
               [0.0, 1.0, 0.0],
               [0.0, 0.0, 1.0]
             ]

      assert BufferEncoder.encode(gaze) == [[0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]
    end

    test "encodes a goal and an attention region as their wire forms" do
      goal = %Goal{sender_id: "LM_0", sender_type: :gsg, location: [1.0, 2.0, 3.0]}
      region = %AttentionRegion{locations: [[0.0, 0.0, 0.0]], weights: [1.0]}

      assert BufferEncoder.encode(goal)["kind"] == "goal"

      assert BufferEncoder.encode(region) == %{
               "kind" => "attention_region",
               "locations" => [[0.0, 0.0, 0.0]],
               "weights" => [1.0]
             }
    end

    test "encodes times as ISO 8601, so a log line is readable" do
      assert BufferEncoder.encode(~U[2026-10-27 12:00:00Z]) == "2026-10-27T12:00:00Z"
      assert BufferEncoder.encode(~N[2026-10-27 12:00:00]) == "2026-10-27T12:00:00"
      assert BufferEncoder.encode(~D[2026-10-27]) == "2026-10-27"
      assert BufferEncoder.encode(~T[12:00:00]) == "12:00:00"
    end

    test "encodes an action as the map it crosses a boundary as" do
      # Monty registers one encoder for the whole `Action` family; every member
      # answers `to_map/1`, which is the name plus its parameters.
      action = %Monty.Frameworks.Actions.TurnLeft{agent_id: "agent_id_0", rotation_degrees: 90.0}

      assert BufferEncoder.encode(action) == %{
               "action" => "turn_left",
               "agent_id" => "agent_id_0",
               "rotation_degrees" => 90.0
             }
    end

    test "encodes a rotation as the Euler angles in degrees, unrounded" do
      # Monty's registration is scipy's `as_euler("xyz", degrees=True)`, and the
      # numbers it produced are the ones a log keeps.
      {:ok, rotation} = Monty.Geometry.Rotation.from_euler_degrees([10.0, 20.0, 30.0])

      assert [ax, ay, az] = BufferEncoder.encode(rotation)
      assert_in_delta ax, 10.0, 1.0e-9
      assert_in_delta ay, 20.0, 1.0e-9
      assert_in_delta az, 30.0, 1.0e-9
    end

    test "something with no encoding at all says so, rather than being dropped" do
      assert_raise ArgumentError, ~r/cannot encode/, fn ->
        BufferEncoder.encode(self())
      end
    end

    test "a struct nobody registered is an error naming the type" do
      assert_raise ArgumentError, ~r/no encoder for Monty.Frameworks.Models.Buffer/, fn ->
        BufferEncoder.encode(%Thing{value: 1})
      end
    end

    test "what comes out is what a JSON encoder accepts" do
      encoded = BufferEncoder.encode([message(), %{pose: :sm, at: ~D[2026-10-27]}])

      assert {:ok, _json} = Jason.encode(encoded)
    end
  end
end
