defmodule Monty.Frameworks.Models.Buffer.FeatureAtLocationBufferTest do
  use ExUnit.Case, async: true

  alias Monty.Cmp.Message
  alias Monty.Frameworks.Models.Buffer.FeatureAtLocationBuffer, as: Buffer
  alias Monty.Geometry.SurfacePoseVectors

  # Translated from Monty's `tests/unit/frameworks/models/buffer_test.py`, with
  # the same fixtures: a sensor module reports where it is and what it sees, a
  # learning module reports a hypothesis (a location it did not sense), and a
  # view finder-like channel carries no features at all.
  defp percept(sender_id, type, location, opts \\ []) do
    on_object = Keyword.get(opts, :on_object, true)
    features? = Keyword.get(opts, :process_features_in_lm, true)
    displacement = Keyword.get(opts, :displacement)
    pose = if features?, do: pose_features(), else: %{}

    {:ok, message} =
      Message.new(%{
        sender_id: sender_id,
        sender_type: type,
        location: location,
        process_features_in_lm: features?,
        morphological_features: Map.merge(%{"on_object" => on_object}, pose),
        non_morphological_features: %{},
        displacement: displacement
      })

    message
  end

  defp pose_features do
    %{
      "pose_vectors" => SurfacePoseVectors.new([0, 0, 1], [1, 0, 0], [0, 1, 0]),
      "pose_fully_defined" => true
    }
  end

  defp append!(buffer, percepts) do
    assert {:ok, buffer} = Buffer.append(buffer, percepts)
    buffer
  end

  describe "locations" do
    test "only the steps where an input was on the object are kept" do
      buffer =
        Buffer.new()
        |> append!([percept("SM_0", :sm, [1.0, 2.0, 3.0])])
        |> append!([percept("SM_0", :sm, [4.0, 5.0, 6.0], on_object: false)])

      assert Buffer.get_all_locations_on_object(buffer) == [[1.0, 2.0, 3.0]]
    end

    test "the step's location is the mean of the sensor module channels" do
      buffer =
        append!(Buffer.new(), [
          percept("SM_0", :sm, [1.0, 2.0, 3.0]),
          percept("SM_1", :sm, [3.0, 4.0, 5.0]),
          percept("LM_0", :lm, [100.0, 100.0, 100.0])
        ])

      # A learning module's hypothesis is not a place the sensors are at.
      assert buffer.last_location == [2.0, 3.0, 4.0]
      assert Buffer.current_location(buffer) == [2.0, 3.0, 4.0]
    end

    test "a single channel is its own mean" do
      buffer = append!(Buffer.new(), [percept("SM_0", :sm, [1.0, 2.0, 3.0])])

      assert buffer.last_location == [1.0, 2.0, 3.0]
    end

    test "the displacement of the step is kept, from the sensor module's report" do
      buffer =
        append!(Buffer.new(), [
          percept("SM_0", :sm, [1.0, 2.0, 3.0],
            displacement: %{"displacement" => [0.1, 0.2, 0.3]}
          ),
          percept("LM_0", :lm, [1.0, 2.0, 3.0],
            displacement: %{"displacement" => [9.0, 9.0, 9.0]}
          )
        ])

      assert Buffer.current_displacement(buffer) == [0.1, 0.2, 0.3]
    end

    test "a step with no sensor module location is refused, not guessed at" do
      assert {:error, :no_sensor_module_location} =
               Buffer.append(Buffer.new(), [percept("LM_0", :lm, [1.0, 2.0, 3.0])])
    end
  end

  describe "features" do
    test "a channel that missed a step keeps its index, padded with nil" do
      buffer =
        Buffer.new()
        |> append!([percept("SM_0", :sm, [1.0, 2.0, 3.0]), percept("LM_0", :lm, [1.0, 2.0, 3.0])])
        |> append!([percept("SM_0", :sm, [4.0, 5.0, 6.0])])

      features = Buffer.get_all_features_on_object(buffer)

      # Both channels have a row per on-object step; the learning module's
      # second row is padding, which is Monty's NaN.
      assert length(features["SM_0"]["pose_vectors"]) == 2
      assert length(features["LM_0"]["pose_vectors"]) == 2
      assert Enum.all?(List.last(features["LM_0"]["pose_vectors"]), &is_nil/1)
      assert Enum.all?(List.last(features["SM_0"]["pose_vectors"]), &is_number/1)
    end

    test "only a channel that carries features stores pose vectors" do
      buffer =
        append!(Buffer.new(), [
          percept("SM_0", :sm, [0.0, 0.0, 0.0]),
          percept("SM_1", :sm, [2.0, 2.0, 2.0], process_features_in_lm: false)
        ])

      assert Map.has_key?(buffer.features["SM_0"], "pose_vectors")
      refute Map.has_key?(buffer.features["SM_1"], "pose_vectors")
    end

    test "a step reads as its features by channel" do
      buffer =
        Buffer.new()
        |> append!([percept("SM_0", :sm, [1.0, 2.0, 3.0])])
        |> append!([percept("SM_0", :sm, [4.0, 5.0, 6.0])])

      assert %{"SM_0" => %{"pose_vectors" => pose, "on_object" => [1.0]}} = Buffer.at(buffer, 1)
      assert length(pose) == 9
    end
  end

  describe "padding rows to the episode's length" do
    setup do
      buffer =
        Enum.reduce(0..2, Buffer.new(), fn step, buffer ->
          append!(buffer, [percept("SM_0", :sm, [step * 1.0, step * 1.0, step * 1.0])])
        end)

      {:ok, buffer: buffer}
    end

    test "a shorter array is padded with nil to the buffer's length", %{buffer: buffer} do
      padded = Buffer.pad_to_target_length(buffer, [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]])

      assert length(padded) == 3
      assert Enum.take(padded, 2) == [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]
      assert List.last(padded) == [nil, nil, nil]
    end

    test "rows already at the target length come back unchanged", %{buffer: buffer} do
      rows = [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0], [7.0, 8.0, 9.0]]

      assert Buffer.pad_to_target_length(buffer, rows) == rows
    end

    test "longer rows come back unchanged too", %{buffer: buffer} do
      rows = [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0], [7.0, 8.0, 9.0], [10.0, 11.0, 12.0]]

      assert Buffer.pad_to_target_length(buffer, rows) == rows
    end

    test "an explicit target length wins", %{buffer: buffer} do
      padded = Buffer.pad_to_target_length(buffer, [[1.0, 2.0, 3.0]], target_length: 2)

      assert padded == [[1.0, 2.0, 3.0], [nil, nil, nil]]
    end

    test "an empty array needs an explicit width, because it has none", %{buffer: buffer} do
      assert Buffer.pad_to_target_length(buffer, [], target_length: 2, width: 3) == [
               [nil, nil, nil],
               [nil, nil, nil]
             ]
    end

    test "an empty array without a width says what is missing", %{buffer: buffer} do
      assert_raise ArgumentError, ~r/cannot infer a row width/, fn ->
        Buffer.pad_to_target_length(buffer, [])
      end
    end

    test "rows of a different width are refused, not silently reshaped", %{buffer: buffer} do
      assert_raise ArgumentError, ~r/column dimension mismatch/, fn ->
        Buffer.pad_to_target_length(buffer, [[1.0, 2.0, 3.0]], width: 2)
      end
    end
  end

  describe "the episode's statistics" do
    test "a statistic seen for the first time starts a list" do
      buffer = Buffer.update_stats(Buffer.new(), %{"lm_processed_steps" => true})

      assert buffer.stats["lm_processed_steps"] == [true]
      assert length(buffer.stats["time"]) == 1
    end

    test "a statistic already held accumulates" do
      buffer =
        Buffer.new()
        |> Buffer.update_stats(%{"lm_processed_steps" => true})
        |> Buffer.update_stats(%{"lm_processed_steps" => false})

      assert buffer.stats["lm_processed_steps"] == [true, false]
    end

    test "an overall statistic replaces instead of accumulating" do
      buffer = Buffer.add_overall_stats(Buffer.new(), %{"detected_path" => [1.0, 2.0, 3.0]})

      assert buffer.stats["detected_path"] == [1.0, 2.0, 3.0]
      assert buffer.stats["time"] == []
    end

    test "the last entry can be overwritten, as voting does" do
      buffer =
        Buffer.new()
        |> Buffer.update_stats(%{"detected_path" => :before})
        |> Buffer.update_last_stats_entry(%{"detected_path" => :after})

      assert buffer.stats["detected_path"] == [:after]
    end

    test "matching steps, goals and the steps since the last goal are counted" do
      buffer =
        Buffer.new()
        |> Buffer.update_stats(%{"lm_processed_steps" => true})
        |> Buffer.update_stats(%{"lm_processed_steps" => true})
        |> Buffer.update_stats(%{"matching_step_when_output_goal_set" => 1})
        |> Buffer.update_stats(%{"goal_state_achieved" => 1})

      assert Buffer.get_num_matching_steps(buffer) == 2
      assert Buffer.get_num_goals_generated(buffer) == 1
      assert Buffer.get_num_steps_post_output_goal_generated(buffer) == 1
    end

    test "with no goal yet, every matching step is a step since the last goal" do
      buffer =
        Buffer.new()
        |> Buffer.update_stats(%{"lm_processed_steps" => true})
        |> Buffer.update_stats(%{"lm_processed_steps" => true})

      assert Buffer.get_num_steps_post_output_goal_generated(buffer) == 2
    end

    test "the first terminal state is the one that is kept" do
      buffer =
        Buffer.new()
        |> Buffer.update_stats(%{"lm_processed_steps" => true})
        |> Buffer.set_individual_ts("mug", :first_pose)
        |> Buffer.update_stats(%{"lm_processed_steps" => true})
        |> Buffer.set_individual_ts("mug", :second_pose)

      assert buffer.stats["individual_ts_pose"] == :first_pose
      assert buffer.stats["individual_ts_reached_at_step"] == 1
    end
  end

  describe "the length of the first displacement" do
    test "is the ppf's first element, when there is a ppf" do
      buffer =
        Buffer.new()
        |> append!([
          percept("SM_0", :sm, [0.0, 0.0, 0.0], displacement: %{"ppf" => [0.0, 0, 0, 0]})
        ])
        |> append!([
          percept("SM_0", :sm, [0.1, 0.0, 0.0], displacement: %{"ppf" => [0.5, 1.0, 2.0, 3.0]})
        ])

      # Row 1, not row 0: the first step of an episode has no displacement to
      # measure, which is why Monty reads the second row.
      assert Buffer.first_displacement_len(buffer) == 0.5
    end

    test "is the norm of the first displacement when there is no ppf" do
      buffer =
        Buffer.new()
        |> append!([
          percept("SM_0", :sm, [0.0, 0.0, 0.0],
            displacement: %{"displacement" => [0.0, 0.0, 0.0]}
          )
        ])
        |> append!([
          percept("SM_0", :sm, [0.3, 0.4, 0.0],
            displacement: %{"displacement" => [0.3, 0.4, 0.0]}
          )
        ])

      assert Buffer.first_displacement_len(buffer) == 0.5
    end

    test "is nothing when no displacement has been seen" do
      assert Buffer.first_displacement_len(Buffer.new()) == nil
    end
  end

  describe "features that are not pose vectors" do
    test "a matrix-valued feature is flattened like a pose, a scalar is a row of one" do
      buffer =
        append!(Buffer.new(), [
          %{
            percept("SM_0", :sm, [0.0, 0.0, 0.0])
            | morphological_features: %{
                "on_object" => true,
                "orientation" => %Monty.Geometry.OrientationMatrix{
                  value: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
                },
                "gaze" => %Monty.Geometry.GazeDirection{
                  value: [[0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]
                },
                "confidence" => 0.5
              }
          }
        ])

      assert buffer.features["SM_0"]["orientation"] == [
               [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
             ]

      assert length(buffer.features["SM_0"]["gaze"]) == 1
      assert buffer.features["SM_0"]["confidence"] == [[0.5]]
    end
  end

  describe "the first sensory input channel" do
    test "is the first channel a sensor module registered" do
      buffer =
        append!(Buffer.new(), [
          percept("LM_0", :lm, [0.0, 0.0, 0.0]),
          percept("SM_1", :sm, [0.0, 0.0, 0.0])
        ])

      assert Buffer.get_first_sensory_input_channel(buffer) == {:ok, "SM_1"}
    end

    test "an empty buffer has no channels at all" do
      assert Buffer.get_first_sensory_input_channel(Buffer.new()) == {:error, :no_channels}
    end

    test "channels without a sensor module are an error, not a guess" do
      # Appending cannot produce this state — a step without a sensor module has
      # no location — but a buffer restored from a log can arrive in it, and
      # what it must not do then is name a learning module as a sensor.
      buffer = %Buffer{channel_sender_types: %{"LM_0" => :lm}, features: %{"LM_0" => %{}}}

      assert {:error, {:no_sensory_channel, %{"LM_0" => :lm}}} =
               Buffer.get_first_sensory_input_channel(buffer)
    end
  end

  describe "the current pose" do
    test "is the location followed by the channel's pose matrix" do
      buffer = append!(Buffer.new(), [percept("SM_0", :sm, [1.0, 2.0, 3.0])])

      assert {:ok, [location, normal, x, y]} = Buffer.get_current_pose(buffer, "SM_0")
      assert location == [1.0, 2.0, 3.0]
      assert normal == [0.0, 0.0, 1.0]
      assert {x, y} == {[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]}
    end

    test "asks for the first sensory channel by default" do
      buffer =
        append!(Buffer.new(), [
          percept("LM_0", :lm, [0.0, 0.0, 0.0]),
          percept("SM_0", :sm, [1.0, 2.0, 3.0])
        ])

      assert {:ok, [location | _pose]} = Buffer.get_current_pose(buffer)
      assert location == [1.0, 2.0, 3.0]
    end

    test "an unknown channel is an error with the name in it" do
      assert {:error, {:no_such_channel, "SM_9"}} =
               Buffer.get_current_pose(Buffer.new(), "SM_9")
    end
  end

  describe "what a graph update needs" do
    test "is the on-object locations, their features and the episode's frames" do
      # The episode's frames are values, not a series: Monty assigns them
      # directly, which is what replacing a statistic does here.
      buffer =
        Buffer.new()
        |> Buffer.add_overall_stats(%{
          "detected_location_rel_body" => [1.0, 2.0, 3.0],
          "detected_location_on_model" => [4.0, 5.0, 6.0]
        })
        |> append!([percept("SM_0", :sm, [1.0, 2.0, 3.0])])

      infos = Buffer.get_infos_for_graph_update(buffer)

      assert infos.locations == [[1.0, 2.0, 3.0]]
      assert infos.object_location_rel_body == [1.0, 2.0, 3.0]
      assert infos.location_rel_model == [4.0, 5.0, 6.0]
      assert %{"SM_0" => %{"pose_vectors" => [row]}} = infos.features
      assert length(row) == 9
    end

    test "an empty buffer gives an empty update rather than raising" do
      infos = Buffer.get_infos_for_graph_update(Buffer.new())

      assert infos.locations == []
      assert infos.features == %{}
    end
  end

  describe "a reset buffer" do
    test "forgets everything but exists" do
      buffer = append!(Buffer.new(), [percept("SM_0", :sm, [1.0, 2.0, 3.0])])
      reset = Buffer.reset(buffer)

      assert Buffer.size(reset) == 0
      assert reset.locations == []
      assert reset.features == %{}
      assert Buffer.current_location(reset) == nil
    end
  end
end
