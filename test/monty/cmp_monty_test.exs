defmodule Monty.CmpMontyTest do
  @moduledoc """
  Monty's own cases for the CMP's message, goal and attention region, translated.

  Each test names the case in `tests/unit/cmp_test.py` it translates.

  ## All fifteen cases

  Every case in Monty's file is translated, and translating them changed the port
  in four places rather than working around anything:

    * `Message.new/1` already validated what Monty's `Message.__init__` asserts.
    * `Goal.new/1` did not validate its pose features at all, and now does, with
      Monty's own allowance: `pose_fully_defined` may be `nil` (a goal does not
      know how completely the pose it came from was seen — which is exactly what
      the evidence goal generator passes) and a goal with no morphological
      features at all is accepted.
    * `AttentionRegion` was a plain struct that refused nothing, and now has
      `new/2`, which refuses the three malformed shapes Monty's `__post_init__`
      refuses; `uniform/2`, `concat/1` and `Cmp.decode/1` build through it.
    * `Cmp.encode/1` left a rotation inside a goal's `info` as struct fields whose
      quaternion is a tuple — which no JSON encoder can write — and now writes it
      as Euler degrees, the same rule the buffer encoder uses.

  Monty's `encode_goal` is shallow (it answers the goal's live objects) and
  `Cmp.encode/1` is deep (it answers JSON-safe data), so the two encoding cases
  assert the deep form: every field is carried, and the result is JSON.
  """

  use ExUnit.Case, async: true

  alias Monty.Cmp
  alias Monty.Cmp.{AttentionRegion, Goal, Message}
  alias Monty.Geometry.{GazeDirection, Rotation}

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

    # test_goal_missing_pose_vectors_raises_assertion_error
    test "a goal that carries features needs pose vectors too" do
      attributes =
        attributes()
        |> update_in([:morphological_features], &Map.delete(&1, "pose_vectors"))
        |> Map.merge(%{sender_type: :gsg, goal_tolerances: nil})

      assert {:error, {:missing_feature, "pose_vectors"}} = Goal.new(attributes)
    end

    # test_goal_invalid_pose_fully_defined_raises_assertion_error
    test "a goal's flag may be nil, but not a number" do
      # Monty's goal case allows `None` where its message case does not — and the
      # evidence goal generator passes exactly that, because a goal does not know
      # how completely the pose it came from was seen.
      attributes = Map.merge(attributes(), %{sender_type: :gsg, goal_tolerances: nil})

      assert {:ok, %Goal{}} =
               Goal.new(put_in(attributes, [:morphological_features, "pose_fully_defined"], nil))

      assert {:error, {:not_a_boolean, _name, 1}} =
               Goal.new(put_in(attributes, [:morphological_features, "pose_fully_defined"], 1))
    end

    test "a goal that claims no features at all is accepted" do
      # What a salience module proposes: a place to look, and nothing about pose.
      assert {:ok, %Goal{morphological_features: nil}} =
               Goal.new(%{
                 location: [1.0, 2.0, 3.0],
                 morphological_features: nil,
                 sender_id: "test",
                 sender_type: :sm
               })
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

    # test_initialized_with_locations_not_n_by_3_raises_value_error
    test "a location that is not three numbers is refused" do
      # Monty draws locations that are not (N, 3): here, two of them are not.
      assert {:error, {:locations_not_n_by_3, _}} =
               AttentionRegion.new([[0.0, 0.0], [1.0, 1.0, 2.0]], [0.0, 0.0])
    end

    # test_initialized_with_weights_not_1d_raises_value_error
    test "a weight that is not one number is refused" do
      assert {:error, {:weights_not_one_dimensional, _}} =
               AttentionRegion.new([[0.0, 0.0, 0.0], [1.0, 1.0, 1.0]], [[0.0], [1.0]])
    end

    # test_initialized_with_mismatched_number_of_locations_and_weights_raises_value_error
    test "two counts that disagree are refused" do
      assert {:error, {:count_mismatch, 2, 1}} =
               AttentionRegion.new([[0.0, 0.0, 0.0], [1.0, 1.0, 1.0]], [0.0])
    end
  end

  # --- the goal's wire form -------------------------------------------------

  describe "a goal's wire form" do
    # Monty's `goal_dict`: a gaze goal at [0, 1.5, 0], a confidence of one, no
    # tolerances, and the hypothesis it was proposed to test in its info — with a
    # rotation, which is the value that has to be written as numbers.
    defp goal do
      {:ok, goal} =
        Goal.new(%{
          location: [0.0, 1.5, 0.0],
          morphological_features: %{
            "pose_vectors" => %GazeDirection{
              value: [[-1.0, -1.0, -1.0], [nil, nil, nil], [nil, nil, nil]]
            },
            "pose_fully_defined" => nil,
            "on_object" => 1
          },
          non_morphological_features: nil,
          confidence: 1.0,
          pass_message: true,
          process_features_in_lm: true,
          sender_id: "LM_0",
          sender_type: :gsg,
          goal_tolerances: nil,
          info: %{
            "proposed_surface_loc" => [0.0, 1.5, 0.0],
            "hypothesis_to_test" => %{
              "graph_id" => "mug",
              "location" => [0.0, 1.5, 0.0],
              "rotation" => Rotation.identity(),
              "scale" => 1.0,
              "evidence" => 1.0
            },
            "achieved" => false,
            "matching_step_when_output_goal_set" => nil
          }
        })

      goal
    end

    # test_encode
    test "every field of the goal is carried, and a rotation inside its info is angles" do
      goal = goal()
      encoded = Cmp.encode(goal)

      fields =
        goal |> Map.from_struct() |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()

      assert encoded |> Map.keys() |> Enum.sort() == Enum.sort(["kind" | fields])

      assert encoded["location"] == [0.0, 1.5, 0.0]
      assert encoded["confidence"] == 1.0
      assert encoded["sender_id"] == "LM_0"
      assert encoded["sender_type"] == "GSG"

      # The hypothesis travels with the goal, and its rotation is written the way
      # the buffer encoder writes one: Euler angles in degrees, unrounded.
      assert get_in(encoded, ["info", "hypothesis_to_test", "graph_id"]) == "mug"

      assert get_in(encoded, ["info", "hypothesis_to_test", "rotation"]) ==
               Rotation.to_euler_degrees(Rotation.identity(), nil)
    end

    # test_json_serialization
    test "the wire form is JSON, and comes back unchanged" do
      encoded = goal() |> Cmp.encode()

      assert encoded |> Jason.encode!() |> Jason.decode!() == encoded
    end
  end
end
