defmodule Monty.Frameworks.Models.MotorPolicies.SurfacePolicyCurvatureInformedTest do
  use ExUnit.Case, async: true

  alias Monty.Cmp.Message
  alias Monty.Context
  alias Monty.Frameworks.Actions.ActionSamplers.ConstantSampler
  alias Monty.Frameworks.Actions.{MoveTangentially, OrientHorizontal, OrientVertical}
  alias Monty.Frameworks.Models.MotorPolicies.MotorPolicyResult
  alias Monty.Frameworks.Models.MotorPolicies.SurfacePolicyCurvatureInformed
  alias Monty.Frameworks.Models.MotorSystemState.{AgentState, SensorState}
  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Geometry.{Rotation, SurfacePoseVectors}

  @agent "agent_id_0"
  @sensor "view_finder"
  @identity Rotation.identity()

  # -- fixtures ------------------------------------------------------------

  # A percept on a surface whose normal faces the agent, with the two principal
  # curvature directions given, and the curvatures' magnitudes.
  defp percept(options \\ []) do
    [first, second] = Keyword.get(options, :curvatures, [1.0, 5.0])

    {:ok, message} =
      Message.new(
        location: Keyword.get(options, :location, [0.0, 0.0, 0.0]),
        morphological_features: %{
          "pose_vectors" =>
            SurfacePoseVectors.new(
              Keyword.get(options, :normal, [0.0, 0.0, 1.0]),
              Keyword.get(options, :direction_1, [1.0, 0.0, 0.0]),
              Keyword.get(options, :direction_2, [0.0, 1.0, 0.0])
            ),
          "pose_fully_defined" => Keyword.get(options, :pose_defined, true)
        },
        non_morphological_features: %{
          "object_coverage" => 0.9,
          "mean_depth" => 0.03,
          "min_depth" => 0.025,
          "principal_curvatures" => [first, second]
        },
        confidence: 1.0,
        pass_message: true,
        process_features_in_lm: true,
        sender_id: "patch",
        sender_type: :sm
      )

    message
  end

  defp state do
    %{
      @agent => %AgentState{
        sensors: %{
          @sensor => %SensorState{position: [0.0, 0.0, 0.0], rotation: @identity}
        },
        position: [0.0, 0.0, 0.0],
        rotation: @identity
      }
    }
  end

  defp policy(options \\ []) do
    SurfacePolicyCurvatureInformed.new(
      agent_id: @agent,
      alpha: Keyword.get(options, :alpha, 0.0),
      pc_alpha: Keyword.get(options, :pc_alpha, 0.5),
      max_pc_bias_steps: Keyword.get(options, :max_pc_bias_steps, 2),
      min_general_steps: Keyword.get(options, :min_general_steps, 0),
      min_heading_steps: Keyword.get(options, :min_heading_steps, 100),
      action_sampler:
        ConstantSampler.new(
          actions: [MoveTangentially],
          translation_distance: 0.05,
          direction: [0.0, 0.0, 0.0]
        )
    )
  end

  # The tangential step follows a vertical orienting, so a policy that has just
  # oriented vertically is the state in which a direction is chosen.
  defp after_orienting_vertically(policy) do
    %{
      policy
      | last_surface_policy_action: %OrientVertical{
          agent_id: @agent,
          rotation_degrees: 0.0,
          down_distance: 0.0,
          forward_distance: 0.0
        }
    }
  end

  defp step(policy, options \\ []) do
    SurfacePolicyCurvatureInformed.call(
      policy,
      Context.new(0),
      %{@agent => %{@sensor => %{"depth" => [[2.0, 2.0], [2.0, 2.0]]}}},
      state(),
      Keyword.get(options, :percept, percept()),
      nil
    )
  end

  defp tangential_direction(policy, options \\ []) do
    SurfacePolicyCurvatureInformed.tangential_direction(
      policy,
      Context.new(0),
      state(),
      Keyword.get(options, :percept, percept())
    )
  end

  defp points_towards?(direction, expected) do
    SpatialArithmetics.dot(direction, expected) > 1.0 - 1.0e-9
  end

  # -- which curvature it follows -------------------------------------------

  describe "which curvature direction it follows" do
    test "the smallest one to begin with, in absolute value" do
      # Curvatures 1 and 5, directions along +x and +y: the smaller is the first,
      # so the heading points along +x.
      {direction, _policy} = tangential_direction(after_orienting_vertically(policy()))

      assert points_towards?(direction, [1.0, 0.0, 0.0])
    end

    test "and the largest one once the preference has flipped" do
      # Two steps of bias, so the flip happens as the third choice is made.
      policy = after_orienting_vertically(policy(max_pc_bias_steps: 2))

      {_direction, policy} = tangential_direction(policy)
      assert policy.following_pc_counter == 1

      {_direction, policy} = tangential_direction(policy)
      assert policy.following_pc_counter == 2
      assert policy.min_dir_pref

      {direction, policy} = tangential_direction(policy)
      refute policy.min_dir_pref

      # Now it follows the larger curvature, whose direction is +y.
      assert points_towards?(direction, [0.0, 1.0, 0.0])
    end

    test "a curvature that points out of the surface is ignored" do
      # The first curvature's direction is along the agent's z axis, which says
      # more about the re-orienting than about the object.
      percept = percept(direction_1: [0.0, 0.0, 1.0])

      {direction, policy} =
        tangential_direction(after_orienting_vertically(policy()), percept: percept)

      assert policy.pc_is_z_defined
      assert_in_delta Enum.at(direction, 2), 0.0, 1.0e-12
    end

    test "with no fully-defined pose it steps by momentum" do
      {_direction, policy} =
        tangential_direction(after_orienting_vertically(policy()),
          percept: percept(pose_defined: false)
        )

      refute policy.using_pc_guide
      assert policy.ignoring_pc_counter == 1
    end

    test "and will not consider curvature again until enough plain steps have passed" do
      policy =
        after_orienting_vertically(policy(min_general_steps: 2))
        |> Map.put(:ignoring_pc_counter, 0)

      {_direction, policy} = tangential_direction(policy, percept: percept(pose_defined: false))
      assert policy.ignoring_pc_counter == 1

      {_direction, policy} = tangential_direction(policy, percept: percept(pose_defined: false))
      assert policy.ignoring_pc_counter == 2

      {_direction, policy} = tangential_direction(policy)
      assert policy.using_pc_guide
    end
  end

  # -- the direction that flipped -------------------------------------------

  describe "a curvature direction that flipped" do
    test "is flipped back, because the surface is what it is" do
      # The previous heading was 0 (up); the new one is 180 degrees round, which
      # is the same line with the other sign.
      policy = %{
        after_orienting_vertically(policy())
        | prev_angle: 0.0,
          tangential_angle: :math.pi(),
          tangential_vec: [0.0, -1.0, 0.0]
      }

      percept = percept(direction_1: [0.0, -1.0, 0.0], direction_2: [1.0, 0.0, 0.0])

      {direction, _policy} = tangential_direction(policy, percept: percept)

      assert points_towards?(direction, [0.0, 1.0, 0.0])
    end
  end

  # -- not walking where it has been ----------------------------------------

  describe "heading somewhere it has already been" do
    test "turns round on a curvature direction that has only just started" do
      # Two places, both a step ahead of where the sensor is now; the current
      # place is the last one, because that is the reference.
      policy = %{
        after_orienting_vertically(policy())
        | tangent_locs: [[0.0, 0.01, 0.0], [0.0, 0.02, 0.0], [0.0, 0.0, 0.0]],
          tangent_norms: List.duplicate([0.0, 0.0, 1.0], 3),
          tangential_angle: 0.0,
          tangential_vec: [0.0, 1.0, 0.0],
          prev_angle: 0.0
      }

      percept = percept(direction_1: [0.0, 1.0, 0.0], direction_2: [1.0, 0.0, 0.0])

      {direction, policy} = tangential_direction(policy, percept: percept)

      # Down instead of up — and it is still following the curvature, because the
      # direction was right and only its sign was wrong.
      assert points_towards?(direction, [0.0, -1.0, 0.0])
      refute policy.setting_new_heading
      assert policy.using_pc_guide
      assert policy.following_pc_counter == 1
    end

    test "keeps its heading when no heading is free" do
      # Eight places round a small circle with the same normal: every heading is
      # within the conflict angle of one of them, so the search runs out.
      ring =
        for step <- 0..7 do
          angle = step * :math.pi() / 4.0
          [0.01 * :math.sin(angle), 0.01 * :math.cos(angle), 0.0]
        end

      # The current place is the last one, at the centre of the ring.
      policy = %{
        after_orienting_vertically(policy())
        | tangent_locs: ring ++ [[0.0, 0.0, 0.0]],
          tangent_norms: List.duplicate([0.0, 0.0, 1.0], length(ring) + 1),
          tangential_angle: 0.0,
          tangential_vec: [0.0, 1.0, 0.0]
      }

      percept = percept(direction_1: [0.0, 1.0, 0.0], direction_2: [1.0, 0.0, 0.0])

      {direction, _policy} = tangential_direction(policy, percept: percept)

      assert points_towards?(direction, [0.0, 1.0, 0.0])
    end

    test "a place on another surface is not a place it has been" do
      # Same location, but the surface there faces away: a different surface.
      policy = %{
        after_orienting_vertically(policy())
        | tangent_locs: [[0.0, 0.01, 0.0], [0.0, 0.02, 0.0], [0.0, 0.0, 0.0]],
          tangent_norms: [[1.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 0.0, 1.0]],
          tangential_angle: 0.0,
          tangential_vec: [0.0, 1.0, 0.0],
          prev_angle: 0.0
      }

      percept = percept(direction_1: [0.0, 1.0, 0.0], direction_2: [1.0, 0.0, 0.0])

      {direction, policy} = tangential_direction(policy, percept: percept)

      assert points_towards?(direction, [0.0, 1.0, 0.0])
      refute policy.setting_new_heading
    end
  end

  # -- what a step looks like -----------------------------------------------

  describe "taking a step" do
    test "it remembers the place it is leaving when it has just oriented vertically" do
      {%MotorPolicyResult{actions: [action]}, policy} =
        step(after_orienting_vertically(policy()), percept: percept(location: [0.1, 0.2, 0.3]))

      assert %MoveTangentially{} = action
      assert policy.tangent_locs == [[0.1, 0.2, 0.3]]
      assert policy.tangent_norms == [[0.0, 0.0, 1.0]]
    end

    test "it says which curvature it followed" do
      {%MotorPolicyResult{telemetry: telemetry}, _policy} =
        step(after_orienting_vertically(policy()))

      assert telemetry.pc_heading == :min
      assert telemetry.avoidance_heading == false
      assert telemetry.z_defined_pc == nil
    end

    test "and that it followed none when the pose is not defined" do
      {%MotorPolicyResult{telemetry: telemetry}, _policy} =
        step(after_orienting_vertically(policy()), percept: percept(pose_defined: false))

      assert telemetry.pc_heading == :no
    end

    test "and not when the last action was something else" do
      {%MotorPolicyResult{actions: [action]}, policy} = step(policy())

      assert %OrientHorizontal{} = action
      assert policy.tangent_locs == []
    end
  end

  # -- starting again -------------------------------------------------------

  describe "resetting" do
    test "forgets the places, the curvature and the counters" do
      used = %{
        after_orienting_vertically(policy())
        | tangent_locs: [[0.0, 0.0, 0.0]],
          tangent_norms: [[0.0, 0.0, 1.0]],
          using_pc_guide: true,
          min_dir_pref: false,
          following_pc_counter: 5,
          prev_angle: 1.0,
          tangential_angle: 1.0,
          tangential_vec: [1.0, 0.0, 0.0]
      }

      reset = SurfacePolicyCurvatureInformed.reset(used)

      assert reset.tangent_locs == []
      assert reset.tangent_norms == []
      assert reset.tangential_angle == nil
      assert reset.tangential_vec == nil
      assert reset.min_dir_pref
      refute reset.using_pc_guide
      assert reset.prev_angle == nil
      assert reset.following_pc_counter == 0
      assert reset.ignoring_pc_counter == reset.min_general_steps
      assert reset.last_surface_policy_action == nil
    end
  end
end
