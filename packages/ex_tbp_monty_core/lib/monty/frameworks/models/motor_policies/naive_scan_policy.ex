defmodule Monty.Frameworks.Models.MotorPolicies.NaiveScanPolicy do
  @moduledoc """
  A policy that scans the object in a square spiral and nothing else.

  Mirrors `tbp/monty/frameworks/models/motor_policies.py::NaiveScanPolicy`, the
  simplest thing that collects a view worth matching: look up, turn left, look
  down, turn right, each by the same fixed amount, with each leg one step longer
  than the last on alternating sides:

      1x up, 1x left, 2x down, 2x right, 3x up, 3x left, ...

  Monty draws the picture: `|_ _ _|` round and round, outward. What makes it
  worth having is that nothing in it is learned: every action is fixed at
  construction, so it is the policy an experiment uses to ask what the *sensor*
  sees rather than what a policy decides.

  It is an `InformedPolicy` in Monty, but it overrides the step completely: the
  percept, the state, the observations and the goal are all ignored. The
  constructor still takes an action sampler, as Monty's does, and never draws
  from it — the actions it makes are the four it was built with.
  """

  @behaviour Monty.Frameworks.Models.MotorPolicies.MotorPolicy

  alias Monty.Frameworks.Actions.ActionSamplers.ActionSampler
  alias Monty.Frameworks.Actions.{LookDown, LookUp, TurnLeft, TurnRight}
  alias Monty.Frameworks.Models.MotorPolicies.MotorPolicyResult

  @enforce_keys [:action_sampler, :agent_id, :fixed_amount]
  defstruct action_sampler: nil,
            agent_id: nil,
            fixed_amount: nil,
            steps_per_action: 1,
            current_action_id: 0,
            step_on_action: 0

  @type t :: %__MODULE__{
          action_sampler: ActionSampler.t(),
          agent_id: atom() | String.t(),
          fixed_amount: float(),
          steps_per_action: pos_integer(),
          current_action_id: non_neg_integer(),
          step_on_action: non_neg_integer()
        }

  @doc """
  A spiral scanner for `:agent_id`, turning `:fixed_amount` degrees a leg.

  The action sampler is required because Monty's constructor takes one — it is
  never asked for anything.
  """
  @spec new(keyword()) :: t()
  def new(options) do
    %__MODULE__{
      action_sampler: Keyword.fetch!(options, :action_sampler),
      agent_id: Keyword.fetch!(options, :agent_id),
      fixed_amount: Keyword.fetch!(options, :fixed_amount)
    }
  end

  @doc """
  The next action of the spiral, and nothing else.

  `motor_only_step` stays false: every one of these actions is something the
  learning modules want to see, which is the whole point of scanning.
  """
  @impl true
  @spec call(
          t(),
          Monty.Context.t(),
          map() | nil,
          Monty.Frameworks.Models.MotorSystemState.t(),
          Monty.Cmp.Message.t() | nil,
          Monty.Cmp.Goal.t() | nil
        ) :: {MotorPolicyResult.t(), t()}
  def call(%__MODULE__{} = policy, _ctx, _observations, _state, _percept, _goal) do
    policy = check_cycle_action(policy)
    policy = %{policy | step_on_action: policy.step_on_action + 1}

    {%MotorPolicyResult{actions: [Enum.at(actions(policy), policy.current_action_id)]}, policy}
  end

  @doc """
  Moves to the next leg of the spiral once the current one is long enough.

  Monty's `check_cycle_action`. After the second and the fourth leg of each
  circuit the leg gets one step longer, so the square grows by one on every
  side.
  """
  @spec check_cycle_action(t()) :: t()
  def check_cycle_action(%__MODULE__{} = policy) do
    if policy.step_on_action == policy.steps_per_action do
      advance_leg(policy)
    else
      policy
    end
  end

  defp advance_leg(%__MODULE__{} = policy) do
    policy = %{
      policy
      | current_action_id: policy.current_action_id + 1,
        step_on_action: 0
    }

    cond do
      policy.current_action_id == 2 ->
        %{policy | steps_per_action: policy.steps_per_action + 1}

      policy.current_action_id == 4 ->
        %{policy | current_action_id: 0, steps_per_action: policy.steps_per_action + 1}

      true ->
        policy
    end
  end

  # The four legs of a circuit, in Monty's order: up, left, down, right. They are
  # built once, at construction, because they never change.
  defp actions(%__MODULE__{} = policy) do
    [
      %LookUp{agent_id: policy.agent_id, rotation_degrees: policy.fixed_amount},
      %TurnLeft{agent_id: policy.agent_id, rotation_degrees: policy.fixed_amount},
      %LookDown{agent_id: policy.agent_id, rotation_degrees: policy.fixed_amount},
      %TurnRight{agent_id: policy.agent_id, rotation_degrees: policy.fixed_amount}
    ]
  end

  @doc "Starts the next episode at the first leg, with legs one step long."
  @impl true
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = policy) do
    %{policy | steps_per_action: 1, current_action_id: 0, step_on_action: 0}
  end

  @doc "Nothing to report: the spiral is fixed at construction."
  @impl true
  @spec state_dict(t()) :: map()
  def state_dict(%__MODULE__{}), do: %{}
end
