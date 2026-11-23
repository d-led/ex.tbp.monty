defmodule Monty.Frameworks.Models.MotorPolicies.BasePolicy do
  @moduledoc """
  A policy that takes one sampled action, whatever the step looked like.

  Mirrors `tbp/monty/frameworks/models/motor_policies.py::BasePolicy`, the
  bottom of the policy hierarchy: it ignores the observations, the state, the
  percept and the goal, and asks its sampler for an action. What it is for is
  the experiments that only need the body to wander — and being the parent that
  every other policy is built on.

  The sampler is a `Monty.Frameworks.Actions.ActionSamplers` struct, as Monty's
  is, and the stream it draws from is the episode's one: `ctx.rng`, the same
  stream every module draws from, read where Monty reads it. The policy holds
  none of its own (`docs/monty-differences.md` §2.5).
  """

  @behaviour Monty.Frameworks.Models.MotorPolicies.MotorPolicy

  alias Monty.Frameworks.Actions.ActionSamplers.ActionSampler
  alias Monty.Frameworks.Models.MotorPolicies.MotorPolicyResult

  @enforce_keys [:action_sampler, :agent_id]
  defstruct action_sampler: nil, agent_id: nil

  @type t :: %__MODULE__{
          action_sampler: ActionSampler.t(),
          agent_id: atom() | String.t()
        }

  @doc """
  A policy that takes whatever `:action_sampler` chooses for `:agent_id`.
  """
  @spec new(keyword()) :: t()
  def new(options) do
    %__MODULE__{
      action_sampler: Keyword.fetch!(options, :action_sampler),
      agent_id: Keyword.fetch!(options, :agent_id)
    }
  end

  @doc """
  One sampled action, and nothing else.

  `motor_only_step` stays false: a single sample is a real move, and the
  learning modules have something to look at afterwards.
  """
  @impl true
  @spec call(
          t(),
          Monty.Context.t(),
          term(),
          Monty.Frameworks.Models.MotorSystemState.t(),
          Monty.Cmp.Message.t() | nil,
          Monty.Cmp.Goal.t() | nil
        ) :: {MotorPolicyResult.t(), t()}
  def call(%__MODULE__{} = policy, ctx, _observations, _state, _percept, _goal) do
    action = ActionSampler.sample(policy.action_sampler, policy.agent_id, ctx)

    {%MotorPolicyResult{actions: [action]}, policy}
  end

  @doc """
  Nothing to forget: the stream is the context's, not the policy's.

  Monty's reset is a no-op for the same reason.
  """
  @impl true
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = policy), do: policy

  @doc "Nothing to report."
  @impl true
  @spec state_dict(t()) :: map()
  def state_dict(%__MODULE__{}), do: %{}
end
