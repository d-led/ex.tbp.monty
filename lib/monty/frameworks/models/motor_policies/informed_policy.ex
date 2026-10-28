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

  Monty's `_handle_successful_jump` hook is `handle_successful_jump/1`, a no-op
  here and overridden by `SurfacePolicy`. The jump step itself,
  `goal_driven_actions/4`, is public for the same reason: `SurfacePolicy` is a
  subclass in Monty and a second struct here, so it calls the shared step rather
  than inheriting it (`docs/monty-bugs.md` §2.9).

  ## What "empty space" means

  `_should_undo_jump` reads `observations[agent_id][sensor_id]["depth"]` and
  takes its centre pixel, as Monty's positioning procedure does. That is the
  shape Monty's habitats report and the shape this reads; when an environment is
  ported, the reader moves to `PositioningProcedures` where Monty keeps it
  (`docs/monty-bugs.md` §2.7).
  """

  @behaviour Monty.Frameworks.Models.MotorPolicies.MotorPolicy

  alias Monty.Cmp
  alias Monty.Frameworks.Actions.ActionSamplers.ActionSampler
  alias Monty.Frameworks.Actions.{SetAgentPose, SetSensorRotation}
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
            rng: nil,
            use_goal_driven_actions: false,
            undo_action: nil,
            is_jumping: false,
            is_undoing_jump: false,
            pre_jump_state: nil,
            undo_jump_actions: []

  @type t :: %__MODULE__{
          action_sampler: Monty.Frameworks.Actions.ActionSamplers.ActionSampler.t(),
          agent_id: atom() | String.t(),
          rng: :rand.state() | nil,
          use_goal_driven_actions: boolean(),
          undo_action: Monty.Frameworks.Actions.Action.t() | nil,
          is_jumping: boolean(),
          is_undoing_jump: boolean(),
          pre_jump_state: Monty.Frameworks.Models.MotorSystemState.AgentState.t() | nil,
          undo_jump_actions: [Monty.Frameworks.Actions.Action.t()]
        }

  @typedoc """
  A policy that can be driven by goals: the fields the jump machinery reads.

  Both policies have them, because Monty gives every subclass the jump state
  through inheritance; here they are matched as a map instead
  (`docs/monty-bugs.md` §2.9).
  """
  @type jump_state :: %{
          required(:agent_id) => atom() | String.t(),
          required(:use_goal_driven_actions) => boolean(),
          required(:is_jumping) => boolean(),
          required(:is_undoing_jump) => boolean(),
          required(:pre_jump_state) =>
            Monty.Frameworks.Models.MotorSystemState.AgentState.t() | nil,
          required(:undo_jump_actions) => [Monty.Frameworks.Actions.Action.t()],
          optional(atom()) => term()
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
  def call(%__MODULE__{} = policy, ctx, observations, state, percept, goal) do
    case goal_driven_actions(policy, observations, state, goal) do
      {:result, result, policy} -> {result, policy}
      {:continue, policy} -> off_object_recovery(policy, ctx, percept)
    end
  end

  # -- staying on the object -----------------------------------------------

  defp off_object_recovery(%__MODULE__{} = policy, ctx, percept) do
    cond do
      on_object?(percept) ->
        {action, policy} = sample(policy, ctx)

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

  # The stream is threaded through the policy, as Monty threads it through the
  # context (`docs/monty-bugs.md` §2.5).
  defp sample(%__MODULE__{} = policy, ctx) do
    rng = ActionSampler.stream(policy.action_sampler, policy.rng, ctx)
    {action, rng} = ActionSampler.sample(policy.action_sampler, policy.agent_id, rng)

    {action, %{policy | rng: rng}}
  end

  # -- jumping --------------------------------------------------------------

  # Monty reaches this through inheritance: `SurfacePolicy` is an
  # `InformedPolicy` and calls `self._goal_driven_actions`. A struct cannot be
  # a subclass of another, so the same step is a public function that takes any
  # policy carrying the jump fields — both policies do, because Monty gives them
  # both to every subclass (`docs/monty-bugs.md` §2.9).
  @doc """
  One step's worth of goal-driven work: judge a jump in flight, or start one.

  Answers `{:result, result, policy}` when the step is decided here, and
  `{:continue, policy}` when the caller should go on to its own behaviour.
  """
  @spec goal_driven_actions(jump_state(), map() | nil, map(), Cmp.Goal.t() | nil) ::
          {:result, MotorPolicyResult.t(), jump_state()} | {:continue, jump_state()}
  def goal_driven_actions(
        %{use_goal_driven_actions: false} = policy,
        _observations,
        _state,
        _goal
      ),
      do: {:continue, policy}

  def goal_driven_actions(policy, observations, state, goal) do
    case jump_outcome(policy, observations, state) do
      {:result, _result, _policy} = landed -> landed
      {:continue, policy} -> start_jump(policy, state, goal)
    end
  end

  defp start_jump(policy, _state, nil), do: {:continue, policy}

  defp start_jump(policy, state, %Cmp.Goal{} = goal) do
    {actions, policy} = jump(policy, state, goal)
    {:result, %MotorPolicyResult{actions: actions}, policy}
  end

  defp jump_outcome(%{is_jumping: false} = policy, _observations, _state),
    do: {:continue, policy}

  defp jump_outcome(%{is_undoing_jump: true} = policy, _observations, state) do
    assert_undo_jump_was_successful(policy, state)
    {:continue, reset_jump_state(policy)}
  end

  defp jump_outcome(policy, observations, _state) do
    if empty_space?(policy, observations) do
      {:result, %MotorPolicyResult{actions: policy.undo_jump_actions},
       %{policy | is_undoing_jump: true}}
    else
      # The object is in view, so the hypothesis test can go ahead from here.
      {:continue, policy |> MotorPolicies.successful_jump() |> reset_jump_state()}
    end
  end

  @doc """
  What to do once a jump has landed with the object in view.

  Monty's `_handle_successful_jump`, a no-op here and overridden by
  `SurfacePolicy`; the policy's own module is asked, because a struct cannot
  override a private function (`docs/monty-bugs.md` §2.9).
  """
  @impl true
  @spec handle_successful_jump(t()) :: t()
  def handle_successful_jump(%__MODULE__{} = policy), do: policy

  # Monty stores the agent's state before a jump so it can put it back, and
  # asserts that putting it back worked. The assertion is worth keeping: an
  # environment that cannot restore a pose breaks every later measurement.
  defp jump(policy, state, %Cmp.Goal{} = goal) do
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

  @doc """
  The orientation every sensor shares, or a refusal to plan a jump.

  Every sensor an action moves is moved at once, so they all keep the
  orientation the jump was planned in. Monty asserts it rather than assuming it,
  and so does this — with the empty case spelled out, which Monty's loop does not
  (`docs/monty-bugs.md` §1.5). Public because `JumpToGoal` needs the same check
  and Monty writes it out twice (§2.9).
  """
  @spec shared_sensor_rotation(%{required(:sensors) => map()}) :: Rotation.t()
  def shared_sensor_rotation(%{sensors: sensors}) do
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
  # sensor will see. Monty writes this out twice — here and in `JumpToGoal`,
  # identically — so it is one public function (§2.9).
  @doc """
  The pose that looks along the goal's direction, from the goal's location.

  Monty's `_derive_set_agent_pose_from_goal`, in both `InformedPolicy` and
  `JumpToGoal`.
  """
  @spec set_agent_pose_from_goal(
          %{required(:agent_id) => atom() | String.t(), optional(atom()) => term()},
          Cmp.Goal.t()
        ) :: SetAgentPose.t()
  def set_agent_pose_from_goal(policy, %Cmp.Goal{} = goal) do
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

  defp empty_space?(policy, observations) do
    MotorPolicies.depth_at_center(observations, policy.agent_id, @view_finder) >=
      @empty_space_depth
  end

  defp assert_undo_jump_was_successful(%{pre_jump_state: nil}, _state) do
    raise "an undo jump finished with no pre-jump state to check it against"
  end

  defp assert_undo_jump_was_successful(policy, state) do
    current = Map.fetch!(state, policy.agent_id)
    before = policy.pre_jump_state

    if current.position != before.position do
      raise "an undo jump left the agent at #{inspect(current.position)}, not #{inspect(before.position)}"
    end

    if current.rotation != before.rotation do
      raise "an undo jump left the agent turned away from where it started"
    end
  end

  defp reset_jump_state(policy) do
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
  @spec reset(jump_state()) :: jump_state()
  def reset(%{} = policy) do
    %{
      policy
      | rng: nil,
        undo_action: nil,
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
