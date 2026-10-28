defmodule Monty.Frameworks.Models.MotorPolicies.InformedPolicy do
  @moduledoc """
  A policy that reads the percept: stay on the object, or step back onto it.

  Mirrors `tbp/monty/frameworks/models/motor_policies.py::InformedPolicy`, the
  first policy that is worth running. It samples an action while the sensor is
  on the object; when the sensor arrives somewhere with nothing under it, it
  takes the *opposite* of the last action, which is Monty's way of getting back
  onto the object without a map. The remembered action is inverted again each
  time it is used, so a sensor that keeps leaving the object walks back and
  forth across the edge instead of walking away.

  ## Jumps

  With `:use_goal_driven_actions` it will also teleport — `SetAgentPose` at the
  goal's location, facing along the goal's direction — which is how a goal
  generator's "look at this part of the mug" reaches the body. A jump can land
  in empty space or inside an object, so the next step judges it from the depth
  at the centre of the view finder: more than a metre means nothing is there,
  and the jump is undone with the pose and sensor rotation it started from.

  Monty's `_handle_successful_jump` hook is not here. Its only user is
  `SurfacePolicy`, which is not ported yet; when it is, that is where its extra
  state goes, and this module will grow the seam with its user rather than
  guessing at the shape.

  ## What "empty space" means

  `_should_undo_jump` reads `observations[agent_id][sensor_id]["depth"]` and
  takes its centre pixel, as Monty's positioning procedure does. That is the
  shape Monty's habitats report and the shape this reads; when an environment is
  ported, the reader moves to `PositioningProcedures` where Monty keeps it.
  """

  @behaviour Monty.Frameworks.Models.MotorPolicies.MotorPolicy

  alias Monty.Cmp
  alias Monty.Frameworks.Actions.SetAgentPose
  alias Monty.Frameworks.Actions.SetSensorRotation
  alias Monty.Frameworks.Models.MotorPolicies
  alias Monty.Frameworks.Models.MotorPolicies.MotorPolicyResult
  alias Monty.Geometry.{GazeDirection, Rotation}

  # Nothing within a metre of the centre of the view finder: the jump landed in
  # empty space or inside something.
  @empty_space_depth 1.0

  @view_finder "view_finder"

  # The identity quaternion, which a jump sets the sensors to because
  # `SetAgentPose` moves them with the agent.
  @identity_quaternion {1.0, 0.0, 0.0, 0.0}

  @enforce_keys [:action_sampler, :agent_id]
  defstruct action_sampler: nil,
            agent_id: nil,
            use_goal_driven_actions: false,
            undo_action: nil,
            is_jumping: false,
            is_undoing_jump: false,
            pre_jump_state: nil,
            undo_jump_actions: []

  @type t :: %__MODULE__{
          action_sampler: Monty.Frameworks.Models.MotorPolicies.BasePolicy.sampler(),
          agent_id: atom() | String.t(),
          use_goal_driven_actions: boolean(),
          undo_action: Monty.Frameworks.Actions.Action.t() | nil,
          is_jumping: boolean(),
          is_undoing_jump: boolean(),
          pre_jump_state: Monty.Frameworks.Models.MotorSystemState.AgentState.t() | nil,
          undo_jump_actions: [Monty.Frameworks.Actions.Action.t()]
        }

  @doc """
  A policy that samples for `:agent_id`, and jumps when `:use_goal_driven_actions`.
  """
  @spec new(keyword()) :: t()
  def new(options) do
    %__MODULE__{
      action_sampler: Keyword.fetch!(options, :action_sampler),
      agent_id: Keyword.fetch!(options, :agent_id),
      use_goal_driven_actions: Keyword.get(options, :use_goal_driven_actions, false)
    }
  end

  @doc """
  One step: a jump if one was asked for, otherwise a sample or a step back.

  A jump that is still in flight is judged here first: undoing it takes the
  whole step, and landing on something means the sample can continue as usual.
  """
  @impl true
  @spec call(
          t(),
          Monty.Context.t(),
          map() | nil,
          Monty.Frameworks.Models.MotorSystemState.t(),
          Cmp.Message.t() | nil,
          Cmp.Goal.t() | nil
        ) :: {MotorPolicyResult.t(), t()}
  def call(%__MODULE__{} = policy, _ctx, observations, state, percept, goal) do
    case goal_driven(policy, observations, state, goal) do
      {:result, result, policy} -> {result, policy}
      {:continue, policy} -> off_object_recovery(policy, percept)
    end
  end

  # -- staying on the object -----------------------------------------------

  defp off_object_recovery(%__MODULE__{} = policy, percept) do
    cond do
      on_object?(percept) ->
        action = policy.action_sampler.(policy.agent_id)

        {%MotorPolicyResult{actions: [action]},
         %{policy | undo_action: MotorPolicies.undo_last_action(action)}}

      policy.undo_action != nil ->
        # Remembering the opposite of what we are about to do is what keeps the
        # sensor near the edge rather than walking it away.
        undo = policy.undo_action

        {%MotorPolicyResult{actions: [undo]},
         %{policy | undo_action: MotorPolicies.undo_last_action(undo)}}

      true ->
        # Nothing to go back to: this is the first step, or the sensor arrived
        # off the object without having moved onto it.
        {%MotorPolicyResult{}, policy}
    end
  end

  # A step with no percept has nothing to say about where the sensor is, and
  # sampling is what a policy does when it is not recovering.
  defp on_object?(nil), do: true
  defp on_object?(%Cmp.Message{} = percept), do: Cmp.Message.on_object?(percept)

  # -- jumping --------------------------------------------------------------

  defp goal_driven(
         %__MODULE__{use_goal_driven_actions: false} = policy,
         _observations,
         _state,
         _goal
       ),
       do: {:continue, policy}

  defp goal_driven(%__MODULE__{} = policy, observations, state, goal) do
    case jump_outcome(policy, observations, state) do
      {:result, _result, _policy} = landed -> landed
      {:continue, policy} -> start_jump(policy, state, goal)
    end
  end

  defp start_jump(%__MODULE__{} = policy, _state, nil), do: {:continue, policy}

  defp start_jump(%__MODULE__{} = policy, state, %Cmp.Goal{} = goal) do
    {actions, policy} = jump(policy, state, goal)
    {:result, %MotorPolicyResult{actions: actions}, policy}
  end

  defp jump_outcome(%__MODULE__{is_jumping: false} = policy, _observations, _state),
    do: {:continue, policy}

  defp jump_outcome(%__MODULE__{is_undoing_jump: true} = policy, _observations, state) do
    assert_undo_jump_was_successful(policy, state)
    {:continue, reset_jump_state(policy)}
  end

  defp jump_outcome(%__MODULE__{} = policy, observations, _state) do
    if empty_space?(policy, observations) do
      {:result, %MotorPolicyResult{actions: policy.undo_jump_actions},
       %{policy | is_undoing_jump: true}}
    else
      # The object is in view, so the hypothesis test can go ahead from here.
      {:continue, reset_jump_state(policy)}
    end
  end

  # Monty stores the agent's state before a jump so it can put it back, and
  # asserts that putting it back worked. The assertion is worth keeping: an
  # environment that cannot restore a pose breaks every later measurement.
  defp jump(%__MODULE__{} = policy, state, %Cmp.Goal{} = goal) do
    pre_jump = Map.fetch!(state, policy.agent_id)
    first_sensor_rotation = shared_sensor_rotation(pre_jump)

    set_agent_pose = set_agent_pose_from_goal(policy, goal)

    actions = [
      set_agent_pose,
      %SetSensorRotation{agent_id: policy.agent_id, rotation_quat: @identity_quaternion}
    ]

    undo_jump_actions = [
      %SetAgentPose{
        agent_id: policy.agent_id,
        location: pre_jump.position,
        rotation_quat: Rotation.to_quaternion(pre_jump.rotation)
      },
      %SetSensorRotation{
        agent_id: policy.agent_id,
        rotation_quat: Rotation.to_quaternion(first_sensor_rotation)
      }
    ]

    {actions,
     %{
       policy
       | is_jumping: true,
         pre_jump_state: pre_jump,
         undo_jump_actions: undo_jump_actions
     }}
  end

  # Every sensor an action moves is moved at once, so they all keep the
  # orientation the jump was planned in. Monty asserts it rather than assuming
  # it, and so does this.
  defp shared_sensor_rotation(%{sensors: sensors}) do
    rotations = sensors |> Map.values() |> Enum.map(& &1.rotation) |> Enum.uniq()

    case rotations do
      [rotation] ->
        rotation

      [] ->
        Rotation.identity()

      _several ->
        raise "sensors are not identical in orientation, so a jump cannot restore them"
    end
  end

  # The goal's direction is where the agent should be looking, so the agent has
  # to be turned to face it: pitch up or down to its height, then yaw round to
  # its bearing. No roll, because which way is up does not matter for what the
  # sensor will see.
  defp set_agent_pose_from_goal(%__MODULE__{} = policy, %Cmp.Goal{} = goal) do
    [looking_x, looking_y, looking_z] = looking_direction(goal)

    yaw = :math.atan2(-looking_x, -looking_z)
    pitch = :math.asin(looking_y)

    {:ok, rotation} =
      Rotation.from_euler_degrees([radians_to_degrees(pitch), radians_to_degrees(yaw), 0.0])

    %SetAgentPose{
      agent_id: policy.agent_id,
      location: goal.location,
      rotation_quat: Rotation.to_quaternion(rotation)
    }
  end

  defp looking_direction(%Cmp.Goal{morphological_features: features}) do
    case Map.fetch!(features, "pose_vectors") do
      %GazeDirection{} = gaze -> GazeDirection.direction(gaze)
      other -> raise ArgumentError, "a jump needs a gaze direction, got #{inspect(other)}"
    end
  end

  defp radians_to_degrees(radians), do: radians * 180.0 / :math.pi()

  defp empty_space?(%__MODULE__{} = policy, observations) do
    depth_at_center(observations, policy.agent_id, @view_finder) >= @empty_space_depth
  end

  defp depth_at_center(observations, agent_id, sensor_id) do
    depth =
      observations
      |> Map.fetch!(agent_id)
      |> Map.fetch!(sensor_id)
      |> Map.fetch!("depth")

    rows = length(depth)
    columns = depth |> hd() |> length()

    depth
    |> Enum.at(div(rows, 2))
    |> Enum.at(div(columns, 2))
  end

  defp assert_undo_jump_was_successful(%__MODULE__{pre_jump_state: nil}, _state) do
    raise "an undo jump finished with no pre-jump state to check it against"
  end

  defp assert_undo_jump_was_successful(%__MODULE__{} = policy, state) do
    current = Map.fetch!(state, policy.agent_id)
    before = policy.pre_jump_state

    if current.position != before.position do
      raise "an undo jump left the agent at #{inspect(current.position)}, not #{inspect(before.position)}"
    end

    if current.rotation != before.rotation do
      raise "an undo jump left the agent turned away from where it started"
    end
  end

  defp reset_jump_state(%__MODULE__{} = policy) do
    %{
      policy
      | is_jumping: false,
        is_undoing_jump: false,
        pre_jump_state: nil,
        undo_jump_actions: []
    }
  end

  # -- what it remembers ----------------------------------------------------

  @doc "Starts the next episode: no jump in flight, and no action to undo."
  @impl true
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = policy) do
    %__MODULE__{
      policy
      | undo_action: nil,
        is_jumping: false,
        is_undoing_jump: false,
        pre_jump_state: nil,
        undo_jump_actions: []
    }
  end

  @doc "Nothing to report: what it knows is the action it would undo."
  @impl true
  @spec state_dict(t()) :: map()
  def state_dict(%__MODULE__{}), do: %{}
end
