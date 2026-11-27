defmodule Monty.CmpMontyTest do
  @moduledoc """
  Monty's own cases for the CMP's message, goal and attention region, translated.

  Each test names the case in `tests/unit/cmp_test.py` it translates.

  ## What could not be translated, and what it says about the port

  Seven of Monty's fifteen cases are about constructors, and the port does not
  validate two of the three types it builds:

    * `test_message_missing_pose_vectors_raises_assertion_error`,
      `test_message_invalid_pose_vectors_raises_assertion_error` and
      `test_message_invalid_pose_fully_defined_raises_assertion_error` **are**
      translated: `Message.new/1` validates exactly what Monty's `__init__`
      asserts (a pose vector of a known type, and a boolean flag), answering
      `{:ok, message}` or `{:error, reason}`.
    * `test_goal_missing_pose_vectors_raises_assertion_error` and
      `test_goal_invalid_pose_fully_defined_raises_assertion_error` are **not**,
      and this is a divergence rather than an omission: Monty's `Goal` inherits
      `Message`'s assertions (with `pose_fully_defined` also allowed to be
      `None`), and the port's `Goal.new/1` validates only the sender type, the
      confidence and the location. A malformed goal is accepted. Recorded here so
      it is not silently lost; fixing it is a change to a live path (both
      `Goal.new/1` call sites) and belongs with them.
    * `test_initialized_with_locations_not_n_by_3_raises_value_error`,
      `test_initialized_with_weights_not_1d_raises_value_error` and
      `test_initialized_with_mismatched_number_of_locations_and_weights_raises_value_error`
      are **not**: `AttentionRegion` is a plain struct here, so nothing refuses a
      region whose lengths disagree. Its only producers are `uniform/2` and
      `concat/1`, both translated below, which cannot build one.
    * `test_encode` and `test_json_serialization` are **not**: Monty's
      `encode_goal` answers a dict of the goal's *live* objects and the case
      compares it with the dict the goal was built from. The port encodes once,
      through `Cmp.encode/1`, to JSON-safe data — the claim that case makes (that
      the wire form carries every field) is `Cmp.encode/1`'s own test's to make.
  """

  use ExUnit.Case, async: true

  alias Monty.Cmp
  alias Monty.Cmp.{AttentionRegion, Message}
  alias Monty.Geometry.GazeDirection

  defp message(sender_type, location) do
    {:ok, message} =
      Message.new(%{
        location: location,
        morphological_features: %{
          "pose_vectors" => %GazeDirection{
            value: [[1.0, 0.0, 0.0], [nil, nil, nil], [nil, nil, nil]]
          },
          "pose_fully_defined" => true
        },
        non_morphological_features: %{},
        confidence: 1.0,
        pass_message: true,
        sender_id: "#{sender_type}_0",
        sender_type: sender_type,
        process_features_in_lm: false
      })

    message
  end

  # --- the message ---------------------------------------------------------

  # test_is_from_sm
  test "a message knows whether the sensor module sent it" do
    assert Message.from_sensor_module?(message(:sm, [0.0, 0.0, 0.0]))
    refute Message.from_sensor_module?(message(:lm, [0.0, 0.0, 0.0]))
  end

  # test_location_mean_filters_out_none_locations
  test "the mean location is taken over the messages that have one" do
    messages = [
      message(:sm, [0.0, 0.0, 0.0]),
      message(:sm, nil),
      message(:sm, [2.0, 4.0, 6.0])
    ]

    assert Cmp.location_mean(messages) == [1.0, 2.0, 3.0]
  end

  # test_location_mean_none_when_no_location
  test "no location anywhere is no mean" do
    assert Cmp.location_mean([]) == nil
    assert Cmp.location_mean([message(:sm, nil)]) == nil
  end

  # --- the attributes a message is built from ------------------------------

  describe "the attributes a message is built from" do
    # Monty's own malformed message: a gaze direction and a flag, no pose vectors.
    defp attributes do
      %{
        location: nil,
        morphological_features: %{
          "pose_vectors" => %GazeDirection{
            value: [[1.0, 0.0, 0.0], [nil, nil, nil], [nil, nil, nil]]
          },
          "pose_fully_defined" => true
        },
        non_morphological_features: %{},
        confidence: 1.0,
        pass_message: true,
        sender_id: "SM_0",
        sender_type: :sm,
        process_features_in_lm: true
      }
    end

    # test_message_missing_pose_vectors_raises_assertion_error
    test "a message that processes features needs pose vectors" do
      attributes =
        update_in(attributes(), [:morphological_features], &Map.delete(&1, "pose_vectors"))

      assert {:error, _reason} = Message.new(attributes)
    end

    # test_message_invalid_pose_vectors_raises_assertion_error
    test "pose vectors have to be one of the three pose types" do
      # Monty's malformed value is a 2 by 2 array; here it is any value that is
      # not a pose struct.
      attributes =
        put_in(attributes(), [:morphological_features, "pose_vectors"], [[1.0, 0.0], [0.0, 1.0]])

      assert {:error, _reason} = Message.new(attributes)
    end

    # test_message_invalid_pose_fully_defined_raises_assertion_error
    test "the fully-defined flag has to be a boolean" do
      attributes = put_in(attributes(), [:morphological_features, "pose_fully_defined"], 1)

      assert {:error, _reason} = Message.new(attributes)
    end
  end

  # --- the attention region -------------------------------------------------

  describe "an attention region" do
    # test_uniform_gives_every_location_the_weight
    test "a uniform region weighs every location the same" do
      locations = [[0.0, 0.0, 0.0], [1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]
      weight = AttentionRegion.max_weight()

      region = AttentionRegion.uniform(locations, weight)

      assert region.locations == locations
      assert region.weights == [weight, weight, weight]
    end

    # test_concat_keeps_every_location_and_weight_in_order
    test "concatenating regions keeps every location and weight in order" do
      first =
        AttentionRegion.uniform([[0.0, 0.0, 0.0], [1.0, 1.0, 1.0]], AttentionRegion.max_weight())

      second =
        AttentionRegion.uniform([[2.0, 2.0, 2.0]], AttentionRegion.max_weight() / 2.0)

      joined = AttentionRegion.concat([first, second])

      assert joined.locations == first.locations ++ second.locations
      assert joined.weights == first.weights ++ second.weights
    end

    test "concatenating nothing is an empty region" do
      # Monty's case covers this branch inside the same test: no regions, no
      # locations, no weights, and a length of zero.
      assert AttentionRegion.empty?(AttentionRegion.concat([]))
    end
  end
end
