defmodule Monty.Frameworks.Models.MotorPolicies.JumpToGoal do
  @moduledoc """
  A policy that teleports the agent to a goal, and takes it back if that lands
  somewhere useless.

  Mirrors `tbp/monty/frameworks/models/motor_policies.py::JumpToGoal`, the
  policy a distant agent's selector reaches for when a learning module has a
  hypothesis worth testing. A jump is two actions — `SetAgentPose` at the goal's
  location facing along the goal's direction, and an identity
  `SetSensorRotation` so the sensors keep the orientation the jump was planned
  in — and it always remembers the two actions that would put the agent back
  where it started.

  It is meant to be called twice: once to jump, and once to judge where the jump
  landed. Landing on the object is the end of it, and the selector moves on to
  the next policy; landing anywhere else — empty space, or inside something —
  answers with the undo actions instead. The judgement reads the percept
  (`on_object`), not the depth, which is where it differs from `InformedPolicy`'s
  version of the same idea.

  With no jump in flight and no goal it raises `NoGoalProvided`, because a
  selector that routes a goal to this policy has already decided there is one;
  a run configured to suppress runtime errors gets a warning and no action
  instead.

  `:sensor_id` is stored and never read, as in Monty, whose docstring says it is
  for a depth-at-centre calculation this policy no longer does.
  """

  @behaviour Monty.Frameworks.Models.MotorPolicies.MotorPolicy

  require Logger

  alias Monty.Cmp
  alias Monty.Frameworks.Actions.{SetAgentPose, SetSensorRotation}
  alias Monty.Frameworks.Models.MotorPolicies.{InformedPolicy, MotorPolicyResult}
  alias Monty.Frameworks.Models.MotorPolicies.NoGoalProvided
  alias Monty.Geometry.Rotation

  # `SetAgentPose` moves the sensors with the agent, so a jump sets them back to
  # no rotation of their own.
  @identity_quaternion {1.0, 0.0, 0.0, 0.0}

  @enforce_keys [:agent_id, :sensor_id]
  defstruct agent_id: nil,
            sensor_id: nil,
            undo_action: nil,
            is_jumping: false,
            is_undoing_jump: false,
            pre_jump_state: nil,
            undo_jump_actions: []

  @type t :: %__MODULE__{
          agent_id: atom() | String.t(),
          sensor_id: atom() | String.t(),
          undo_action: Monty.Frameworks.Actions.Action.t() | nil,
          is_jumping: boolean(),
          is_undoing_jump: boolean(),
          pre_jump_state: Monty.Frameworks.Models.MotorSystemState.AgentState.t() | nil,
          undo_jump_actions: [Monty.Frameworks.Actions.Action.t()]
        }

  @doc """
  A jump policy for `:agent_id`, judging with `:sensor_id`.

  `:sensor_id` is kept for the sake of the constructor Monty has, and unused.
  """
  @spec new(keyword()) :: t()
  def new(options) do
    %__MODULE__{
      agent_id: Keyword.fetch!(options, :agent_id),
      sensor_id: Keyword.fetch!(options, :sensor_id)
    }
  end

  @doc """
  A jump, or a verdict on the last one.

  A jump in flight is judged first: an undo answers with the actions that put the
  agent back, and a landing on the object leaves the step free to start the next
  jump — or, with no goal, to ask for nothing at all.
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
  def call(%__MODULE__{is_jumping: true} = policy, ctx, _observations, state, percept, goal) do
    case settle_jump(policy, percept) do
      {:undo, result, policy} -> {result, policy}
      {:continue, policy} -> next_move(policy, ctx, state, goal, :just_landed)
    end
  end

  def call(%__MODULE__{} = policy, ctx, _observations, state, _percept, goal) do
    next_move(policy, ctx, state, goal, :fresh)
  end

  # A jump that landed well leaves the agent somewhere worth looking from, and
  # with nothing more to do this step the policy asks for nothing rather than
  # for another jump it has not been told about.
  defp next_move(policy, _ctx, _state, nil, :just_landed),
    do: {%MotorPolicyResult{}, policy}

  defp next_move(policy, ctx, _state, nil, :fresh), do: no_goal(policy, ctx)

  defp next_move(policy, _ctx, state, %Cmp.Goal{} = goal, _when),
    do: jump(policy, state, goal)

  defp no_goal(%__MODULE__{} = policy, %{suppress_runtime_errors: true}) do
    Logger.warning("No goal provided")
    {%MotorPolicyResult{}, policy}
  end

  defp no_goal(%__MODULE__{}, _ctx), do: raise(NoGoalProvided)

  # -- judging the jump -----------------------------------------------------

  defp settle_jump(%__MODULE__{} = policy, percept) do
    if undo?(percept) do
      {:undo, %MotorPolicyResult{actions: policy.undo_jump_actions}, reset_jump(policy)}
    else
      {:continue, reset_jump(policy)}
    end
  end

  # A jump is undone when the sensor is no longer on the object: that covers both
  # landing in empty space and landing inside something.
  defp undo?(nil), do: false
  defp undo?(%Cmp.Message{} = percept), do: not Cmp.Message.on_object?(percept)

  # -- jumping --------------------------------------------------------------

  defp jump(%__MODULE__{} = policy, state, %Cmp.Goal{} = goal) do
    pre_jump = Map.fetch!(state, policy.agent_id)
    sensor_rotation = InformedPolicy.shared_sensor_rotation(pre_jump)

    actions = [
      InformedPolicy.set_agent_pose_from_goal(policy, goal),
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
        rotation_quat: Rotation.to_quaternion(sensor_rotation)
      }
    ]

    {%MotorPolicyResult{actions: actions, status: :in_progress},
     %{
       policy
       | is_jumping: true,
         pre_jump_state: pre_jump,
         undo_jump_actions: undo_jump_actions
     }}
  end

  defp reset_jump(%__MODULE__{} = policy) do
    %{policy | is_jumping: false, pre_jump_state: nil, undo_jump_actions: []}
  end

  # -- what it remembers ----------------------------------------------------

  @doc "Starts the next episode with no jump in flight."
  @impl true
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = policy), do: reset_jump(%{policy | undo_action: nil})

  @doc """
  The jump in flight, as plain values.

  Monty's memento, written with one name and read with another — see
  `docs/monty-bugs.md` §1.6. There is no load path here, so this is what a run
  records and not something a policy is restored from.
  """
  @impl true
  @spec state_dict(t()) :: map()
  def state_dict(%__MODULE__{} = policy) do
    %{
      is_jumping: policy.is_jumping,
      pre_jump_state: policy.pre_jump_state,
      undo_jump_actions: policy.undo_jump_actions
    }
  end
end
