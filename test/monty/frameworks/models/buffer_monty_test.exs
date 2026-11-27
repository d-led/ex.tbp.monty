defmodule Monty.Frameworks.Models.BufferMontyTest do
  @moduledoc """
  Monty's own cases for the buffer and its encoder, translated.

  Each test names the case in `tests/unit/frameworks/models/buffer_test.py` it
  translates. Monty's fixture is a `Mock` a test can bend into any shape; here it
  is a `%Monty.Cmp.Message{}`, which is what the buffer actually takes.

  The file is `async: false`: `BufferEncoder`'s registry is one entry in the
  application's environment, so two tests registering an encoder for the same
  type at once would see each other. Every encoder case unregisters what it
  registered.

  Three statements differ because the port states them differently, and each
  says so at the test that needs it:

    * Padding writes `nil`, where Monty writes NaN — the port's own comment says
      `nil` is what Monty's NaN means here, because a channel that did not send a
      row is *absent*, not immeasurable.
    * An invalid encoder raises `ArgumentError`, where Monty raises `TypeError`
      and its own case is named "raises value error".
    * `pad_to_target_length/3` takes the buffer as its target and calls the
      column count `:width` (Monty's `new_val_len`).

  ## What could not be translated

  Five of the fifteen encoder cases are about mechanisms the port does not have:

    * `test_encode_uses_method_resolution_order_encoder` — Monty walks the class
      MRO, so a fake mixin's encoder can answer for a subclass that has none.
      Elixir has no inheritance: a struct knows only its own module, so the
      lookup is exact. The encoder's moduledoc states the guarantee that replaces
      it (a type with its own encoder always uses it) and this case is that
      guarantee's negative image.
    * `test_buffer_encoder_encodes_numpy_ndarray_by_default`,
      `test_buffer_encoder_encodes_numpy_ints_by_default`,
      `test_buffer_encoder_encodes_numpy_bools_by_default` and
      `test_buffer_encoder_encodes_torch_tensors_by_default` — numpy arrays and
      scalars and torch tensors are foreign libraries the port does not carry.
      What those four cases assert is that a foreign array becomes a JSON list;
      the port's arrays *are* lists, so there is nothing to convert and no
      encoder to test.
  """

  use ExUnit.Case, async: false

  alias Monty.Cmp
  alias Monty.Cmp.Message
  alias Monty.Frameworks.Actions.{ActionJSONEncoder, LookDown, LookUp, TurnLeft, TurnRight}
  alias Monty.Frameworks.Models.Buffer.{BufferEncoder, FeatureAtLocationBuffer}
  alias Monty.Frameworks.Models.MotorSystemState.SensorState
  alias Monty.Geometry.{Rotation, SurfacePoseVectors}

  @agent "test"

  defp pose_vectors do
    %SurfacePoseVectors{value: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]}
  end

  # Monty's `create_mock_message`, as the struct the buffer takes: a channel, a
  # place, and whether the sensor was on the object.
  defp message(sender_id, sender_type, location, on_object, options \\ []) do
    %Message{
      sender_id: sender_id,
      sender_type: sender_type,
      location: location,
      process_features_in_lm: Keyword.get(options, :process_features_in_lm, true),
      displacement: Keyword.get(options, :displacement),
      morphological_features: %{
        "pose_vectors" => pose_vectors(),
        "pose_fully_defined" => true,
        "on_object" => if(on_object, do: 1.0, else: 0.0)
      },
      non_morphological_features: %{}
    }
  end

  defp append!(buffer, percepts) do
    {:ok, buffer} = FeatureAtLocationBuffer.append(buffer, percepts)
    buffer
  end

  defp three_steps do
    Enum.reduce(0..2, FeatureAtLocationBuffer.new(), fn index, buffer ->
      value = index * 1.0
      append!(buffer, [message("SM_0", :sm, [value, value, value], true)])
    end)
  end

  defp rows_of(buffer, channel, attribute) do
    buffer
    |> FeatureAtLocationBuffer.get_all_features_on_object()
    |> Map.fetch!(channel)
    |> Map.fetch!(attribute)
  end

  # --- where the sensor has been --------------------------------------------

  # test_get_all_locations_on_object_excludes_off_object_steps
  test "a location is kept only for the steps that were on the object" do
    buffer =
      FeatureAtLocationBuffer.new()
      |> append!([message("SM_0", :sm, [1.0, 2.0, 3.0], true)])
      |> append!([message("SM_0", :sm, [4.0, 5.0, 6.0], false)])

    assert FeatureAtLocationBuffer.get_all_locations_on_object(buffer) == [[1.0, 2.0, 3.0]]
  end

  # test_last_location_is_average_of_sm_channels
  test "the last location is the mean of the sensory channels, and only theirs" do
    sm_0 = message("SM_0", :sm, [1.0, 2.0, 3.0], true)
    sm_1 = message("SM_1", :sm, [3.0, 4.0, 5.0], true)
    # A learning module's own location is not a place the sensor looked from.
    lm = message("LM_0", :lm, [100.0, 100.0, 100.0], true)

    buffer = FeatureAtLocationBuffer.new() |> append!([sm_0, sm_1, lm])

    assert buffer.last_location == [2.0, 3.0, 4.0]
  end

  # test_last_location_single_channel
  test "one sensory channel is its own mean" do
    buffer =
      FeatureAtLocationBuffer.new()
      |> append!([message("SM_0", :sm, [1.0, 2.0, 3.0], true)])

    assert buffer.last_location == [1.0, 2.0, 3.0]
  end

  # test_stores_displacement_from_first_observation
  test "the displacement a percept carries is the buffer's current displacement" do
    displacement = %{"displacement" => [0.1, 0.2, 0.3]}

    buffer =
      FeatureAtLocationBuffer.new()
      |> append!([
        message("SM_0", :sm, [1.0, 2.0, 3.0], true, displacement: displacement),
        message("LM_0", :lm, [1.0, 2.0, 3.0], true, displacement: displacement)
      ])

    assert FeatureAtLocationBuffer.current_displacement(buffer) == [0.1, 0.2, 0.3]
  end

  # --- what was seen --------------------------------------------------------

  # test_get_all_features_on_object_pads_with_nans
  test "a channel that skipped a step is padded, and the padding is absent, not zero" do
    both = [
      message("SM_0", :sm, [1.0, 2.0, 3.0], true),
      message("LM_0", :lm, [1.0, 2.0, 3.0], true)
    ]

    buffer =
      FeatureAtLocationBuffer.new()
      |> append!(both)
      |> append!([message("SM_0", :sm, [4.0, 5.0, 6.0], true)])

    sm_pose_vectors = rows_of(buffer, "SM_0", "pose_vectors")
    lm_pose_vectors = rows_of(buffer, "LM_0", "pose_vectors")

    # Both channels are as long as the episode, so one channel's silence does not
    # shift the other's steps.
    assert length(sm_pose_vectors) == 2
    assert length(lm_pose_vectors) == 2

    assert sm_pose_vectors |> List.flatten() |> Enum.all?(&(&1 != nil))
    assert lm_pose_vectors |> hd() |> Enum.all?(&(&1 != nil))

    # Monty's NaN: the row a channel did not send is absent.
    assert lm_pose_vectors |> Enum.at(1) |> Enum.all?(&is_nil/1)
  end

  # test_only_feature_percepts_store_pose_vectors
  test "a location-only percept stores no features" do
    feature = message("SM_0", :sm, [0.0, 0.0, 0.0], true, process_features_in_lm: true)

    location_only =
      message("SM_1", :sm, [2.0, 2.0, 2.0], true, process_features_in_lm: false)

    buffer = FeatureAtLocationBuffer.new() |> append!([feature, location_only])

    assert Map.has_key?(buffer.features["SM_0"], "pose_vectors")
    refute Map.has_key?(buffer.features["SM_1"], "pose_vectors")
  end

  # --- padding --------------------------------------------------------------

  describe "padding to the episode's length" do
    # test_pads_shorter_array_to_buffer_length
    test "a short array is padded at the end with absent rows" do
      buffer = three_steps()
      existing = [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]

      padded = FeatureAtLocationBuffer.pad_to_target_length(buffer, existing)

      assert length(padded) == 3
      assert Enum.take(padded, 2) == existing
      assert padded |> Enum.at(2) |> Enum.all?(&is_nil/1)
    end

    # test_returns_unchanged_when_already_at_target
    test "an array as long as the episode is left alone" do
      buffer = three_steps()
      existing = [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0], [7.0, 8.0, 9.0]]

      assert FeatureAtLocationBuffer.pad_to_target_length(buffer, existing) == existing
    end

    # test_returns_unchanged_when_longer_than_target
    test "an array longer than the episode is left alone" do
      buffer = three_steps()

      existing = [
        [1.0, 2.0, 3.0],
        [4.0, 5.0, 6.0],
        [7.0, 8.0, 9.0],
        [10.0, 11.0, 12.0],
        [13.0, 14.0, 15.0]
      ]

      assert FeatureAtLocationBuffer.pad_to_target_length(buffer, existing) == existing
    end

    # test_pads_with_explicit_target_length
    test "an explicit target length is how long the answer is" do
      buffer = three_steps()
      existing = [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]

      padded = FeatureAtLocationBuffer.pad_to_target_length(buffer, existing, target_length: 5)

      assert length(padded) == 5
      assert Enum.take(padded, 2) == existing

      assert padded |> Enum.drop(2) |> Enum.all?(fn row -> Enum.all?(row, &is_nil/1) end)
      assert padded |> Enum.all?(fn row -> length(row) == 3 end)
    end

    # test_pads_empty_array_with_explicit_new_val_len
    test "an empty array needs a width, and gets rows of it" do
      padded =
        FeatureAtLocationBuffer.pad_to_target_length(three_steps(), [],
          target_length: 3,
          width: 5
        )

      assert length(padded) == 3
      assert padded |> Enum.all?(fn row -> length(row) == 5 end)
      assert padded |> List.flatten() |> Enum.all?(&is_nil/1)
    end

    # test_raises_error_for_empty_array_without_new_val_len
    test "an empty array with no width to infer is refused" do
      assert_raise ArgumentError, ~r/cannot infer a row width/, fn ->
        FeatureAtLocationBuffer.pad_to_target_length(three_steps(), [])
      end
    end

    # test_raises_error_for_column_dimension_mismatch
    test "a width that disagrees with the rows is refused" do
      error =
        assert_raise ArgumentError, fn ->
          FeatureAtLocationBuffer.pad_to_target_length(
            three_steps(),
            [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]],
            target_length: 4,
            width: 5
          )
        end

      assert error.message =~ "column dimension mismatch"
      assert error.message =~ "3"
      assert error.message =~ "5"
    end
  end

  # --- the encoder ----------------------------------------------------------

  describe "the encoder's registry" do
    setup do
      on_exit(fn -> BufferEncoder.unregister(Message) end)
      on_exit(fn -> BufferEncoder.unregister(SensorState) end)
      :ok
    end

    # test_register_function_encoder
    test "a registered function answers for its type" do
      BufferEncoder.register(Message, fn _message -> 0 end)

      assert BufferEncoder.encode(message("SM_0", :sm, [1.0, 2.0, 3.0], true)) == 0
    end

    # test_register_json_encoder_subclass_encoder
    test "a registered module answers through its own encode" do
      # Monty registers a `json.JSONEncoder` subclass; the port registers anything
      # exporting `encode/1`, which `Cmp` does for the wire forms.
      BufferEncoder.register(Message, Cmp)

      message = message("SM_0", :sm, [1.0, 2.0, 3.0], true)

      assert BufferEncoder.encode(message) == Cmp.encode(message)
    end

    # test_register_invalid_encoder_raises_value_error
    test "anything that is not an encoder is refused" do
      assert_raise ArgumentError, fn -> BufferEncoder.register(Message, nil) end
    end

    # test_unregister_unregisters_encoder
    test "an unregistered type goes back to the default encoding" do
      message = message("SM_0", :sm, [1.0, 2.0, 3.0], true)

      BufferEncoder.register(Message, fn _message -> 0 end)
      assert BufferEncoder.encode(message) == 0

      BufferEncoder.unregister(Message)

      # Monty falls back through the class hierarchy; with no hierarchy here, the
      # fallback is the type's own default encoding — for a message, its wire form.
      assert BufferEncoder.encode(message) == Cmp.encode(message)
    end

    # test_buffer_encoder_encodes_scipy_rotation_by_default
    test "a rotation encodes as its Euler angles in degrees, as scipy answered them" do
      {:ok, rotation} = Rotation.from_euler_degrees([30.0, 45.0, 60.0])

      # Unrounded: a log is compared, not rounded — which is why the encoder asks
      # for the angles without the display rounding.
      assert BufferEncoder.encode(rotation) == Rotation.to_euler_degrees(rotation, nil)
    end

    # test_buffer_encoder_encodes_quaternions_by_default
    test "a quaternion is its four numbers, in order" do
      # Monty encodes `quaternion.as_float_array`; the port's quaternion is the
      # four numbers, which the default encoding writes as a list.
      assert BufferEncoder.encode({0.0, 1.0, 0.0, 0.0}) == [0.0, 1.0, 0.0, 0.0]
    end

    # test_buffer_encoder_encodes_actions_by_default
    test "an action encodes as the action encoder writes it" do
      actions = [
        %LookDown{agent_id: @agent, rotation_degrees: 47.0},
        %LookUp{agent_id: @agent, rotation_degrees: 77.0},
        %TurnLeft{agent_id: @agent, rotation_degrees: 90.0},
        %TurnRight{agent_id: @agent, rotation_degrees: 90.0}
      ]

      for action <- actions do
        assert BufferEncoder.encode(action) == ActionJSONEncoder.encode(action)
      end
    end

    # test_encodes_dataclass_instances_as_dicts_by_default
    test "a struct the encoder knows becomes its fields" do
      state = %SensorState{position: [1.0, 2.0, 3.0], rotation: Rotation.identity()}

      # The fields, with each value encoded by its own default — a nested rotation
      # is angles, not a struct, which is what Monty's encoder does as json walks
      # the object it is handed.
      assert BufferEncoder.encode(state) == %{
               position: [1.0, 2.0, 3.0],
               rotation: Rotation.to_euler_degrees(Rotation.identity(), nil)
             }
    end

    # test_default_dataclass_encoding_overridden_by_registered_dataclass_encoder
    test "registering an encoder for one type leaves the others on their default" do
      sensor_state = %SensorState{position: [1.0, 2.0, 3.0], rotation: Rotation.identity()}

      BufferEncoder.register(SensorState, fn _state -> "CUSTOM_ENCODING" end)

      assert BufferEncoder.encode(sensor_state) == "CUSTOM_ENCODING"

      # Another type keeps the default encoding.
      other = message("LM_0", :lm, [4.0, 5.0, 6.0], true)

      BufferEncoder.unregister(SensorState)
      assert BufferEncoder.encode(other) == Cmp.encode(other)
    end

    # test_registered_encoder_for_inner_dataclass_is_invoked
    test "a registered encoder is applied inside a container, not around it" do
      inner = %SensorState{position: [1.0, 2.0, 3.0], rotation: Rotation.identity()}

      BufferEncoder.register(SensorState, fn _state -> "CUSTOM_ENCODING" end)

      encoded = BufferEncoder.encode(%{inner: inner, plain: 1})

      assert encoded == %{inner: "CUSTOM_ENCODING", plain: 1}
    end
  end
end
