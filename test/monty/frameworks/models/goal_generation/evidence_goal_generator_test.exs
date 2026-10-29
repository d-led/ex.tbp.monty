defmodule Monty.Frameworks.Models.GoalGeneration.EvidenceGoalGeneratorTest do
  use ExUnit.Case, async: true

  alias Monty.Cmp.{Goal, Message}
  alias Monty.Context
  alias Monty.Frameworks.Models.Buffer.FeatureAtLocationBuffer
  alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
  alias Monty.Frameworks.Models.GoalGeneration.EvidenceGoalGenerator
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
  alias Monty.Geometry.{GazeDirection, Rotation, SurfacePoseVectors}

  @pose_flat [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
  @identity Rotation.to_matrix(Rotation.identity())

  # -- objects -------------------------------------------------------------

  # An object is a row of points along x whose `rgba` is its own x coordinate,
  # so where the sensor looked is readable from the observation alone.
  defp model(id, positions) do
    locations = Enum.map(positions, &[&1, 0.0, 0.0])

    features = %{
      "rgba" => Enum.map(positions, fn x -> [x] end),
      "pose_vectors" => List.duplicate(@pose_flat, length(positions)),
      "pose_fully_defined" => List.duplicate([1.0], length(positions))
    }

    GraphObjectModel.new(id) |> GraphObjectModel.build_model(locations, features, nil, nil)
  end

  defp memory(objects) do
    objects
    |> Enum.reduce(GraphMemory.new(features_to_use: %{"patch" => ["rgba", "pose_vectors"]}), fn
      {id, positions}, memory ->
        GraphMemory.add_graph_to_memory(memory, %{"patch" => model(id, positions)}, id)
    end)
    |> GraphMemory.initialize_feature_arrays()
  end

  # A cup that stops where the mug's handle would start, so the two objects
  # disagree about exactly one place.
  defp mug_and_cup, do: memory(%{"mug" => [0.0, 0.1, 0.2], "cup" => [0.0, 0.1]})

  defp learning_module(memory, options \\ []) do
    {:ok, lm} =
      EvidenceGraphLM.new(
        memory,
        Keyword.merge(
          [
            max_match_distance: 0.05,
            tolerances: %{"patch" => %{"rgba" => 0.05}},
            feature_weights: %{"patch" => %{"rgba" => 1.0}}
          ],
          options
        )
      )

    lm
  end

  # A hypothesis space where each object has `evidences`, all of its poses the
  # identity, so only the numbers decide what the module believes.
  defp with_hypotheses(lm, evidences_by_object) do
    hypotheses =
      Map.new(evidences_by_object, fn {object_id, evidences} ->
        {object_id,
         %Hypotheses{
           evidence: evidences,
           locations: List.duplicate([0.0, 0.0, 0.0], length(evidences)),
           poses: List.duplicate(@identity, length(evidences)),
           possible: List.duplicate(true, length(evidences))
         }}
      end)

    lm = %{lm | hypotheses: hypotheses}
    %{lm | current_mlh: EvidenceGraphLM.most_likely_hypothesis(lm)}
  end

  defp looking_from(%{current_mlh: mlh} = lm, rotation),
    do: %{lm | current_mlh: %{mlh | rotation: rotation}}

  # Rotation constructors answer `{:ok, rotation}`; a test that already holds a
  # valid rotation does not need to handle the failure.
  defp aimed({:ok, rotation}), do: rotation

  # -- time ----------------------------------------------------------------

  # A buffer that has processed `steps` matching steps and has generated no
  # goal yet, which is where the schedule counts from.
  defp buffer(steps, options \\ []) do
    stats = %{
      "lm_processed_steps" => List.duplicate(true, steps),
      "goal_state_achieved" => []
    }

    %{
      FeatureAtLocationBuffer.new()
      | stats: stats,
        channel_sender_types: Keyword.get(options, :channels, %{})
    }
  end

  # -- the generator -------------------------------------------------------

  defp generator(lm, options \\ []) do
    EvidenceGoalGenerator.new(Keyword.merge([parent_lm: lm], options))
  end

  defp with_buffer(generator, buffer) do
    lm = %{EvidenceGoalGenerator.parent_lm(generator) | buffer: buffer}
    %{generator | base: %{generator.base | parent_lm: lm}}
  end

  defp with_previous_top_two(generator, previous), do: %{generator | prev_top_mlhs: previous}

  defp with_goal_in_hand(generator, goal),
    do: %{generator | base: %{generator.base | output_goal: goal}}

  defp decide(generator, buffer, seed \\ 1) do
    generator
    |> with_buffer(buffer)
    |> EvidenceGoalGenerator.check_conditions_for_hypothesis_test(Context.new(seed))
  end

  defp mlh(graph_id, rotation) do
    %{
      graph_id: graph_id,
      mlh_id: 0,
      location: [0.0, 0.0, 0.0],
      rotation: rotation,
      scale: 1,
      evidence: 1.0
    }
  end

  # A sensor on the patch channel, in a pose that matches what was stored.
  defp percept(location) do
    {:ok, message} =
      Message.new(
        location: location,
        morphological_features: %{
          "pose_vectors" =>
            SurfacePoseVectors.new([0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]),
          "pose_fully_defined" => true,
          "rgba" => [0.0]
        },
        non_morphological_features: %{},
        confidence: 1.0,
        pass_message: true,
        process_features_in_lm: true,
        sender_id: "patch",
        sender_type: :sm
      )

    message
  end

  defp goal do
    {:ok, goal} = Goal.new(location: [0.0, 0.0, 0.0], sender_id: "LM_0", sender_type: :gsg)
    goal
  end

  # Two objects still neck and neck, which is the only situation where the
  # schedule has to decide rather than know.
  defp undecided do
    mug_and_cup()
    |> learning_module()
    |> with_hypotheses(%{"mug" => [10.0, 9.9], "cup" => [9.95]})
  end

  describe "when to look somewhere new" do
    test "waits for the minimum number of steps after the last goal" do
      lm =
        memory(%{"mug" => [0.0, 0.1, 0.2]})
        |> learning_module()
        |> with_hypotheses(%{"mug" => [2.0, 1.0]})

      generator = generator(lm, min_post_goal_success_steps: 3)

      assert {false, _generator} = decide(generator, buffer(3))
      assert {true, _generator} = decide(generator, buffer(4))
    end

    test "never jumps on patience alone when the minimum is unlimited" do
      lm =
        memory(%{"mug" => [0.0, 0.1, 0.2]})
        |> learning_module()
        |> with_hypotheses(%{"mug" => [2.0, 1.0]})

      assert {false, _generator} = decide(generator(lm), buffer(100))
    end

    test "focuses on the pose when the only object still has several of them" do
      lm =
        memory(%{"mug" => [0.0, 0.1, 0.2]})
        |> learning_module()
        |> with_hypotheses(%{"mug" => [2.0, 1.0]})

      assert {true, generator} = decide(generator(lm, min_post_goal_success_steps: 0), buffer(1))
      assert generator.focus_on_pose
    end

    test "does not jump when the only object has a single hypothesis" do
      lm =
        memory(%{"mug" => [0.0, 0.1, 0.2]})
        |> learning_module()
        |> with_hypotheses(%{"mug" => [2.0]})

      assert {false, generator} = decide(generator(lm, min_post_goal_success_steps: 0), buffer(1))
      refute generator.focus_on_pose
    end

    test "does not jump before anything has been hypothesised" do
      lm = memory(%{"mug" => [0.0, 0.1, 0.2]}) |> learning_module()

      assert {false, _generator} =
               decide(generator(lm, min_post_goal_success_steps: 0), buffer(1))
    end

    test "jumps when one object is clearly ahead, and asks about its pose" do
      lm =
        mug_and_cup()
        |> learning_module()
        |> with_hypotheses(%{"mug" => [10.0, 9.0], "cup" => [1.0]})

      assert {true, generator} = decide(generator(lm, min_post_goal_success_steps: 0), buffer(1))
      assert generator.focus_on_pose
    end

    test "does not jump while the objects are still neck and neck" do
      assert {false, _generator} =
               undecided()
               |> generator(min_post_goal_success_steps: 0)
               |> decide(buffer(1))
    end

    test "sometimes jumps to the pose when one object is only slightly ahead" do
      lm =
        mug_and_cup()
        |> learning_module()
        |> with_hypotheses(%{"mug" => [10.0, 9.0], "cup" => [9.1]})

      generator = generator(lm, min_post_goal_success_steps: 0, elapsed_steps_factor: 1000)

      outcomes = for seed <- 1..20, do: decide(generator, buffer(1), seed) |> elem(0)

      assert Enum.any?(outcomes, & &1), "expected the coin to come up pose at least once"
      assert Enum.any?(outcomes, &(not &1)), "expected the coin to look elsewhere at least once"
    end

    test "jumps when the top two objects swap places" do
      previous = [mlh("cup", Rotation.identity()), mlh("mug", Rotation.identity())]

      assert {true, _generator} =
               undecided()
               |> generator(min_post_goal_success_steps: 0)
               |> with_previous_top_two(previous)
               |> decide(buffer(1))
    end

    test "does not jump when only one of the top two changes" do
      lm =
        memory(%{"mug" => [0.0, 0.1, 0.2], "cup" => [0.0, 0.1], "box" => [0.0, 0.1]})
        |> learning_module()
        |> with_hypotheses(%{"mug" => [10.0, 9.9], "cup" => [9.95], "box" => [9.9]})

      previous = [mlh("mug", Rotation.identity()), mlh("box", Rotation.identity())]

      assert {false, _generator} =
               generator(lm, min_post_goal_success_steps: 0)
               |> with_previous_top_two(previous)
               |> decide(buffer(1))
    end

    test "jumps when the most likely pose of the top object has changed" do
      previous = [mlh("mug", Rotation.identity()), mlh("cup", Rotation.identity())]

      assert {true, _generator} =
               undecided()
               |> looking_from(aimed(Rotation.from_euler_degrees([10.0, 20.0, 30.0])))
               |> generator(min_post_goal_success_steps: 0)
               |> with_previous_top_two(previous)
               |> decide(buffer(1))
    end

    # Monty compares the three Euler angles with `np.all`, so a turn about a
    # single axis — which changes one angle — does not count as a new pose.
    test "does not treat a turn about one axis as a new pose" do
      previous = [mlh("mug", Rotation.identity()), mlh("cup", Rotation.identity())]

      assert {false, _generator} =
               undecided()
               |> looking_from(aimed(Rotation.from_axis_angle([0.0, 0.0, 1.0], :math.pi() / 6)))
               |> generator(min_post_goal_success_steps: 0)
               |> with_previous_top_two(previous)
               |> decide(buffer(1))
    end

    test "jumps on a schedule when nothing else changed, and waits twice as long next time" do
      generator = generator(undecided(), min_post_goal_success_steps: 0)

      assert {true, generator} = decide(generator, buffer(10))
      assert generator.wait_factor == 2

      # Ten steps later is too soon now: the wait has grown to twenty.
      assert {false, _generator} = decide(generator, buffer(10))
    end
  end

  describe "where to look" do
    test "picks the point of the most likely object that the alternative explains worst" do
      memory = mug_and_cup()
      lm = memory |> learning_module() |> with_hypotheses(%{"mug" => [10.0], "cup" => [1.0]})

      generator =
        generator(lm, min_post_goal_success_steps: 0)
        |> with_buffer(buffer(1, channels: %{"patch" => :sm}))

      assert {:ok, target_loc_id, _generator} =
               EvidenceGoalGenerator.compute_graph_mismatch(generator)

      mug_positions =
        memory |> GraphMemory.get_graph("mug", "patch") |> GraphObjectModel.positions()

      # The mug runs to 0.2 along x and the cup stops at 0.1, so the mug's far
      # end is the only place the two graphs really disagree.
      assert Enum.at(mug_positions, target_loc_id) == [0.2, 0.0, 0.0]
    end

    test "remembers what it compared, so a change can be noticed next step" do
      lm =
        mug_and_cup() |> learning_module() |> with_hypotheses(%{"mug" => [10.0], "cup" => [1.0]})

      generator =
        generator(lm, min_post_goal_success_steps: 0)
        |> with_buffer(buffer(1, channels: %{"patch" => :sm}))

      assert {:ok, _target_loc_id, compared} =
               EvidenceGoalGenerator.compute_graph_mismatch(generator)

      assert Enum.map(compared.prev_top_mlhs, & &1.graph_id) == ["mug", "cup"]
    end

    test "says so when the module has no sensory channel to look through" do
      lm =
        mug_and_cup() |> learning_module() |> with_hypotheses(%{"mug" => [10.0], "cup" => [1.0]})

      assert {:error, :no_channels} =
               generator(lm)
               |> with_buffer(buffer(1))
               |> EvidenceGoalGenerator.compute_graph_mismatch()
    end
  end

  describe "the goal it asks for" do
    # Looking at a target 20 cm along x, from just under the surface.
    defp target_info(options) do
      %{
        hypothesis_to_test: mlh("mug", Keyword.get(options, :mlh_rotation, Rotation.identity())),
        target_loc: [0.2, 0.0, 0.0],
        target_surface_normal: [0.0, 0.0, 1.0]
      }
    end

    defp ask_for(observations, target_info) do
      generator =
        learning_module(memory(%{"mug" => [0.0, 0.1, 0.2]}))
        |> generator()
        |> with_buffer(buffer(1, channels: %{"patch" => :sm}))

      EvidenceGoalGenerator.compute_goal_for_target_loc(generator, observations, target_info)
    end

    test "stands off the surface along the learned normal of the target" do
      assert {:ok, goal} = ask_for([percept([0.0, 0.1, -0.5])], target_info([]))

      # The wanted distance to the object is 3 cm, and Monty places the goal one
      # and a half of those off the surface.
      assert goal.location == [0.2, 0.1, -0.5 + 0.045]
    end

    test "rotates the target out of the object's frame through the object's pose" do
      object_pose = aimed(Rotation.from_axis_angle([0.0, 0.0, 1.0], :math.pi() / 2))

      # The MLH rotation turns a displacement into a pose, so it is the inverse
      # of the pose the object is in.
      info = target_info(mlh_rotation: Rotation.invert(object_pose))

      assert {:ok, goal} = ask_for([percept([0.0, 0.0, 0.0])], info)

      assert_in_delta Enum.at(goal.location, 0), 0.0, 1.0e-9
      assert_in_delta Enum.at(goal.location, 1), 0.2, 1.0e-9
      assert_in_delta Enum.at(goal.location, 2), 0.045, 1.0e-9
    end

    test "asks for a gaze with the roll left undefined" do
      assert {:ok, goal} = ask_for([percept([0.0, 0.0, 0.0])], target_info([]))

      assert %{
               "pose_vectors" => %GazeDirection{
                 value: [direction, [nil, nil, nil], [nil, nil, nil]]
               },
               "pose_fully_defined" => nil,
               "on_object" => 1
             } = goal.morphological_features

      # Facing the surface means pointing opposite its normal.
      assert direction == [0.0, 0.0, -1.0]
    end

    test "says who asked, and for what" do
      assert {:ok, goal} = ask_for([percept([0.0, 0.0, 0.0])], target_info([]))

      assert goal.sender_id == "LM_0"
      assert goal.sender_type == :gsg
      assert goal.process_features_in_lm
      assert goal.info["hypothesis_to_test"].graph_id == "mug"
      assert goal.info["achieved"] == nil
    end
  end

  describe "a step" do
    test "generates a goal once the schedule allows it" do
      lm =
        memory(%{"mug" => [0.0, 0.1, 0.2]})
        |> learning_module()
        |> with_hypotheses(%{"mug" => [2.0, 1.0]})

      generator =
        generator(lm, min_post_goal_success_steps: 3)
        |> with_buffer(buffer(4, channels: %{"patch" => :sm}))

      stepped = EvidenceGoalGenerator.step(generator, Context.new(1), [percept([0.0, 0.0, 0.0])])

      assert [%Goal{} = goal] = EvidenceGoalGenerator.output_goals(stepped)
      assert goal.info["hypothesis_to_test"].graph_id == "mug"
    end

    test "drops the goal in hand when the schedule says look nowhere" do
      lm =
        memory(%{"mug" => [0.0, 0.1, 0.2]})
        |> learning_module()
        |> with_hypotheses(%{"mug" => [2.0, 1.0]})

      generator =
        generator(lm)
        |> with_buffer(buffer(100, channels: %{"patch" => :sm}))
        |> with_goal_in_hand(goal())

      stepped = EvidenceGoalGenerator.step(generator, Context.new(1), [percept([0.0, 0.0, 0.0])])

      assert EvidenceGoalGenerator.output_goals(stepped) == []
    end
  end

  describe "starting over" do
    test "forgets the schedule and the goal in hand" do
      generator =
        generator(learning_module(memory(%{"mug" => [0.0, 0.1, 0.2]})))
        |> Map.put(:focus_on_pose, true)
        |> Map.put(:wait_factor, 8)
        |> with_previous_top_two([mlh("mug", Rotation.identity())])
        |> with_goal_in_hand(goal())
        |> EvidenceGoalGenerator.reset()

      refute generator.focus_on_pose
      assert generator.wait_factor == 1
      assert generator.prev_top_mlhs == nil
      assert EvidenceGoalGenerator.output_goals(generator) == []
    end
  end

  describe "from_config/1" do
    test "takes its schedule from the entry an experiment writes" do
      # `learning_module/evidence_1lm_nn5_dod0025.yaml`'s `gsg`, as composed.
      generator =
        EvidenceGoalGenerator.from_config(%{
          "_target_" => "tbp.monty.frameworks.models.goal_generation.EvidenceGoalGenerator",
          "goal_tolerances" => %{"location" => 0.015},
          "elapsed_steps_factor" => 10,
          "min_post_goal_success_steps" => 5,
          "x_percent_scale_factor" => 0.75,
          "desired_object_distance" => 0.025
        })

      assert generator.base.goal_tolerances == %{"location" => 0.015}
      assert generator.elapsed_steps_factor == 10
      assert generator.min_post_goal_success_steps == 5
      assert generator.x_percent_scale_factor == 0.75
      assert generator.desired_object_distance == 0.025
    end

    test "keeps Monty's defaults for what the entry leaves out" do
      # Infinity, so an experiment that does not ask for hypothesis testing does
      # not get it: the agent has to be told to gamble on a look elsewhere.
      generator =
        EvidenceGoalGenerator.from_config(%{
          "_target_" => "tbp.monty.frameworks.models.goal_generation.EvidenceGoalGenerator"
        })

      assert generator.base.goal_tolerances == %{"location" => 0.015}
      assert generator.min_post_goal_success_steps == :infinity
      assert generator.wait_growth_multiplier == 2
    end
  end
end
