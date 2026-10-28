defmodule Monty.Frameworks.Models.MotorPolicies.SurfacePolicyTest do
  use ExUnit.Case, async: true

  alias Monty.Cmp.Message
  alias Monty.Context

  alias Monty.Frameworks.Actions.{
    MoveForward,
    MoveTangentially,
    OrientHorizontal,
    OrientVertical,
    SetAgentPose,
    SetSensorRotation
  }

  alias Monty.Frameworks.Actions.ActionSamplers.ConstantSampler
  alias Monty.Frameworks.Models.MotorPolicies.{MotorPolicyResult, SurfacePolicy}
  alias Monty.Frameworks.Models.MotorSystemState.{AgentState, SensorState}
  alias Monty.Geometry.{Rotation, SurfacePoseVectors}

  @agent "agent_id_0"
  @view_finder "view_finder"
  @identity Rotation.identity()

  # -- fixtures ------------------------------------------------------------

  # A percept a surface sensor would send: how much of the view the object
  # covers, how far away its surface is, and which way that surface faces.
  defp percept(options \\ []) do
    {:ok, message} =
      Message.new(
        location: [0.0, 0.0, 0.0],
        morphological_features: %{
          "pose_vectors" =>
            SurfacePoseVectors.new(
              Keyword.get(options, :normal, [0.0, 0.0, 1.0]),
              [1.0, 0.0, 0.0],
              [0.0, 1.0, 0.0]
            ),
          "pose_fully_defined" => true,
          "on_object" => Keyword.get(options, :on_object, true)
        },
        non_morphological_features: %{
          "object_coverage" => Keyword.get(options, :coverage, 0.8),
          "mean_depth" => Keyword.get(options, :mean_depth, 0.03),
          "min_depth" => Keyword.get(options, :min_depth, 0.025)
        },
        confidence: 1.0,
        pass_message: true,
        process_features_in_lm: true,
        sender_id: "patch",
        sender_type: :sm
      )

    message
  end

  defp state(sensor_depth \\ 0.02) do
    %{
      @agent => %AgentState{
        sensors: %{
          @view_finder => %SensorState{position: [0.0, 0.0, sensor_depth], rotation: @identity}
        },
        position: [0.1, 0.2, 0.3],
        rotation: @identity
      }
    }
  end

  # A world that reports one depth everywhere in the view finder.
  defp observations(depth) do
    %{@agent => %{@view_finder => %{"depth" => [[depth, depth], [depth, depth]]}}}
  end

  defp policy(options \\ []) do
    SurfacePolicy.new(
      Keyword.merge(
        [
          agent_id: @agent,
          alpha: 0.0,
          action_sampler:
            ConstantSampler.new(
              actions: [MoveForward, MoveTangentially],
              translation_distance: 0.05,
              direction: [0.0, 0.0, 0.0]
            )
        ],
        options
      )
    )
  end

  # The actions the cycle passes through, for the states where only the kind
  # matters.
  defp orienting_horizontally,
    do: %OrientHorizontal{
      agent_id: @agent,
      rotation_degrees: 0.0,
      left_distance: 0.0,
      forward_distance: 0.0
    }

  defp orienting_vertically,
    do: %OrientVertical{
      agent_id: @agent,
      rotation_degrees: 0.0,
      down_distance: 0.0,
      forward_distance: 0.0
    }

  defp step(policy, options \\ []) do
    SurfacePolicy.call(
      policy,
      Context.new(0),
      Keyword.get(options, :observations, observations(2.0)),
      Keyword.get(options, :state, state()),
      Keyword.get(options, :percept, percept()),
      Keyword.get(options, :goal)
    )
  end

  defp action_of(policy, options \\ []) do
    {%MotorPolicyResult{actions: [action]}, policy} = step(policy, options)
    {action, policy}
  end

  # -- the cycle -----------------------------------------------------------

  describe "while the object is in view" do
    test "the first step orients horizontally, as if a forward move had been taken" do
      {action, _policy} = action_of(policy())

      assert %OrientHorizontal{} = action
    end

    test "the four actions follow one another in Monty's order" do
      {actions, _policy} =
        Enum.map_reduce(1..4, policy(), fn _step, policy ->
          {%MotorPolicyResult{actions: [action]}, policy} = step(policy)
          {action, policy}
        end)

      assert Enum.map(actions, & &1.__struct__) == [
               OrientHorizontal,
               OrientVertical,
               MoveTangentially,
               MoveForward
             ]
    end

    test "only the vertical orienting is worth showing the learning modules" do
      {actions, _policy} =
        Enum.map_reduce(1..3, policy(), fn _step, policy ->
          {%MotorPolicyResult{actions: [action], motor_only_step: motor_only} = result, policy} =
            step(policy)

          assert motor_only == not match?(%OrientVertical{}, action)
          {result, policy}
        end)

      assert length(actions) == 3
    end
  end

  describe "orienting toward the surface" do
    test "a sideways lean turns the sensor by that much, the short way round the circle" do
      # The normal leans 30 degrees to the agent's right in the agent's own
      # frame, so the sensor turns 30 degrees the other way; the distances are
      # what tan and the exsecant give for a surface 3 cm away.
      {action, _policy} =
        action_of(policy(), percept: percept(normal: [0.5, 0.0, 0.8660254037844387]))

      assert %OrientHorizontal{} = action
      assert_in_delta action.rotation_degrees, -30.0, 1.0e-12
      assert_in_delta action.left_distance, -0.03 * :math.tan(:math.pi() / 6), 1.0e-9

      assert_in_delta action.forward_distance,
                      0.03 * (1.0 - :math.cos(:math.pi() / 6)) / :math.cos(:math.pi() / 6),
                      1.0e-9
    end

    test "an up-and-down lean does the same vertically" do
      policy = %{policy() | last_surface_policy_action: orienting_horizontally()}

      {action, _policy} =
        action_of(policy, percept: percept(normal: [0.0, 0.5, 0.8660254037844387]))

      assert %OrientVertical{} = action
      assert_in_delta action.rotation_degrees, -30.0, 1.0e-12
      assert_in_delta action.down_distance, -0.03 * :math.tan(:math.pi() / 6), 1.0e-9
    end

    test "a surface edge-on to the sensor is a right angle, not a division by zero" do
      {action, _policy} = action_of(policy(), percept: percept(normal: [0.5, 0.0, 0.0]))

      assert %OrientHorizontal{} = action
      assert_in_delta action.rotation_degrees, -90.0, 1.0e-12
    end
  end

  # -- finding the object again --------------------------------------------

  describe "when the sensor has left the object" do
    test "it steps forward when the object is in view but the view is too empty" do
      {action, policy} =
        action_of(policy(),
          percept: percept(coverage: 0.05),
          observations: observations(0.5)
        )

      # depth at the centre, less the distance it wants to keep, less how far
      # the sensor already sits in front of the agent.
      assert %MoveForward{distance: distance} = action
      assert_in_delta distance, 0.5 - 0.025 - 0.02, 1.0e-12
      refute policy.attempting_to_find_object
    end

    test "it searches round a circle in front of it when nothing is in view" do
      {action, policy} = action_of(policy(), percept: percept(coverage: 0.0))

      # A circle four times the desired distance away, stepped round by 30
      # degrees: tan for the sideways move, the exsecant for the way back out.
      radius = 0.025 * 4
      radians = :math.pi() / 6

      assert %OrientHorizontal{rotation_degrees: 30.0} = action
      assert_in_delta action.left_distance, :math.tan(radians) * radius, 1.0e-12

      assert_in_delta action.forward_distance,
                      radius * (1.0 - :math.cos(radians)) / :math.cos(radians),
                      1.0e-12

      assert policy.attempting_to_find_object
      assert policy.touch_search_amount == 30.0
    end

    test "the search keeps going while the sensor is off the object" do
      {_action, policy} = action_of(policy(), percept: percept(coverage: 0.0))
      {action, policy} = action_of(policy, percept: percept(coverage: 0.8))

      assert %OrientHorizontal{rotation_degrees: 30.0} = action
      assert policy.touch_search_amount == 60.0
    end

    test "after a full turn it searches vertically" do
      policy = %{policy() | touch_search_amount: 360.0, attempting_to_find_object: true}

      {action, _policy} = action_of(policy, percept: percept(coverage: 0.0))

      assert %OrientVertical{rotation_degrees: 30.0} = action
    end

    test "after two full turns it searches at random angles" do
      policy = %{policy() | touch_search_amount: 720.0, attempting_to_find_object: true}

      {action, _policy} = action_of(policy, percept: percept(coverage: 0.0))

      assert action.__struct__ in [OrientHorizontal, OrientVertical]
      assert action.rotation_degrees >= -180.0 and action.rotation_degrees <= 180.0
      refute action.rotation_degrees == 30.0
    end
  end

  # -- moving along the surface --------------------------------------------

  describe "moving along the surface" do
    defp after_orienting_vertically(policy),
      do: %{policy | last_surface_policy_action: orienting_vertically()}

    test "it steps by the length the sampler gave" do
      {action, _policy} = action_of(after_orienting_vertically(policy()))

      assert %MoveTangentially{distance: 0.05} = action
    end

    test "it steps four times shorter near an edge" do
      {action, _policy} =
        action_of(after_orienting_vertically(policy()), percept: percept(coverage: 0.5))

      assert %MoveTangentially{distance: 0.0125} = action
    end

    test "it steps much shorter where the object is only a sliver of the view" do
      {action, _policy} =
        action_of(after_orienting_vertically(policy()), percept: percept(coverage: 0.1))

      assert %MoveTangentially{distance: distance} = action
      assert_in_delta distance, 0.05 / 40, 1.0e-12
    end

    test "it moves across the surface rather than into it" do
      # With alpha 0 there is no new direction, so the first step is the
      # reference direction: up, with an agent that is not rotated.
      {action, _policy} = action_of(after_orienting_vertically(policy()))

      assert %MoveTangentially{direction: [x, y, z]} = action
      assert_in_delta x, 0.0, 1.0e-12
      assert_in_delta y, 1.0, 1.0e-12
      assert_in_delta z, 0.0, 1.0e-12

      [normal_x, normal_y, normal_z] = [0.0, 0.0, 1.0]
      assert_in_delta x * normal_x + y * normal_y + z * normal_z, 0.0, 1.0e-12
    end
  end

  # -- jumps ---------------------------------------------------------------

  describe "when a goal moved the agent" do
    defp jumped_policy(options \\ []) do
      %{
        policy(Keyword.merge([use_goal_driven_actions: true], options))
        | is_jumping: true,
          pre_jump_state: %AgentState{
            sensors: %{},
            position: [1.0, 1.0, 1.0],
            rotation: @identity
          },
          undo_jump_actions: [
            %SetAgentPose{
              agent_id: @agent,
              location: [1.0, 1.0, 1.0],
              rotation_quat: {1.0, 0.0, 0.0, 0.0}
            },
            %SetSensorRotation{agent_id: @agent, rotation_quat: {1.0, 0.0, 0.0, 0.0}}
          ]
      }
    end

    test "a jump that landed on the object hands back to the cycle" do
      # The hook remembers the jump as a tangential move, so the cycle carries on
      # with the corrective forward move rather than starting over.
      {%MotorPolicyResult{actions: [action], telemetry: telemetry}, policy} =
        step(jumped_policy(), observations: observations(0.5))

      assert %MoveForward{} = action
      assert telemetry.pc_heading == :jump
      refute policy.is_jumping
    end

    test "a jump that landed in empty space is undone" do
      {%MotorPolicyResult{actions: actions, motor_only_step: motor_only}, policy} =
        step(jumped_policy(), observations: observations(2.0))

      assert [%SetAgentPose{}, %SetSensorRotation{}] = actions
      refute motor_only
      assert policy.is_undoing_jump
    end
  end

  # -- what it remembers ---------------------------------------------------

  describe "what it remembers" do
    test "resetting forgets the search, so the next search starts horizontally again" do
      searched = %{policy() | touch_search_amount: 500.0, attempting_to_find_object: true}

      {action, _policy} =
        action_of(SurfacePolicy.reset(searched), percept: percept(coverage: 0.0))

      assert %OrientHorizontal{rotation_degrees: 30.0} = action
    end

    test "nothing worth reporting, because what it knows is its last action" do
      assert SurfacePolicy.state_dict(policy()) == %{}
    end
  end
end
