defmodule Monty.Frameworks.Models.MotorPolicies.BasePolicy do
  @moduledoc """
  A policy that takes one sampled action, whatever the step looked like.

  Mirrors `tbp/monty/frameworks/models/motor_policies.py::BasePolicy`, the
  bottom of the policy hierarchy: it ignores the observations, the state, the
  percept and the goal, and asks its sampler for an action. What it is for is
  the experiments that only need the body to wander — and being the parent that
  every other policy is built on.

  The sampler is a one-argument function, `agent_id -> action`, because that is
  what `ActionSampler.sample` amounts to once the runtime context's random
  stream has been threaded in. Monty's samplers live in
  `...Actions.ActionSamplers`, which this port still has as planned.
  """

  @behaviour Monty.Frameworks.Models.MotorPolicies.MotorPolicy

  alias Monty.Frameworks.Models.MotorPolicies.MotorPolicyResult

  @enforce_keys [:action_sampler, :agent_id]
  defstruct action_sampler: nil, agent_id: nil

  @type sampler :: (agent_id :: atom() | String.t() -> Monty.Frameworks.Actions.Action.t())

  @type t :: %__MODULE__{action_sampler: sampler(), agent_id: atom() | String.t()}

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
  def call(%__MODULE__{} = policy, _ctx, _observations, _state, _percept, _goal) do
    {%MotorPolicyResult{actions: [policy.action_sampler.(policy.agent_id)]}, policy}
  end

  @doc "Nothing to forget: a sample depends on the sampler, not on the episode."
  @impl true
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = policy), do: policy

  @doc "Nothing to report."
  @impl true
  @spec state_dict(t()) :: map()
  def state_dict(%__MODULE__{}), do: %{}
end
