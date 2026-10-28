defmodule Monty.Frameworks.Models.MotorPolicies.InformedPolicyRandomWalk do
  @moduledoc """
  The random walk `InformedPolicy` does, on its own.

  Mirrors `tbp/monty/frameworks/models/motor_policies.py::InformedPolicyRandomWalk`.
  `InformedPolicy` is a walk *with* a recovery rule: sample while the sensor is
  on the object, and step back while it is not. This policy is that rule without
  the rest of `InformedPolicy`, which is what the distant agent's motor-system
  configs ask for as their selector's default (`distant_2`, `distant_5`): the
  selector routes goals to `JumpToGoal` and `LookAtGoal`, and between goals the
  body wanders.

  There is no momentum here, whatever the word "random walk" suggests: every
  step is an independent draw from the sampler. Monty's own docstring says as
  much — this reproduces what `InformedPolicy` did rather than proposing a
  better walk — and the `alpha` momentum belongs to `SurfacePolicy`'s tangential
  direction, not to this policy.

  The remembered action is inverted every time it is used, so a sensor that keeps
  leaving the object walks back and forth across the edge instead of away.
  """

  @behaviour Monty.Frameworks.Models.MotorPolicies.MotorPolicy

  alias Monty.Cmp
  alias Monty.Frameworks.Actions.ActionSamplers.ActionSampler
  alias Monty.Frameworks.Models.MotorPolicies
  alias Monty.Frameworks.Models.MotorPolicies.MotorPolicyResult

  @enforce_keys [:action_sampler, :agent_id]
  defstruct action_sampler: nil, agent_id: nil, rng: nil, undo_action: nil

  @type t :: %__MODULE__{
          action_sampler: ActionSampler.t(),
          agent_id: atom() | String.t(),
          rng: :rand.state() | nil,
          undo_action: Monty.Frameworks.Actions.Action.t() | nil
        }

  @doc "A walk for `:agent_id`, sampling from `:action_sampler`."
  @spec new(keyword()) :: t()
  def new(options) do
    %__MODULE__{
      action_sampler: Keyword.fetch!(options, :action_sampler),
      agent_id: Keyword.fetch!(options, :agent_id)
    }
  end

  @doc """
  A sampled step on the object, the step back off it, or nothing at all.

  The goal and the motor-system state are ignored: this policy is input-driven,
  and the only input it reads is whether the sensor is still on the object.
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
  def call(%__MODULE__{} = policy, ctx, _observations, _state, percept, _goal) do
    cond do
      on_object?(percept) -> walk(policy, ctx)
      policy.undo_action != nil -> step_back(policy)
      true -> {%MotorPolicyResult{}, policy}
    end
  end

  defp walk(%__MODULE__{} = policy, ctx) do
    {action, policy} = sample(policy, ctx)

    {%MotorPolicyResult{actions: [action]},
     %{policy | undo_action: MotorPolicies.undo_last_action(action)}}
  end

  # Remembering the opposite of what we are about to do, and inverting it again
  # each time it is used, is what keeps the sensor near the edge rather than
  # walking away from it.
  defp step_back(%__MODULE__{} = policy) do
    undo = policy.undo_action

    {%MotorPolicyResult{actions: [undo]},
     %{policy | undo_action: MotorPolicies.undo_last_action(undo)}}
  end

  # A step with no percept has nothing to say about where the sensor is, and
  # sampling is what a walk does — the same reading `InformedPolicy` takes.
  defp on_object?(nil), do: true
  defp on_object?(%Cmp.Message{} = percept), do: Cmp.Message.on_object?(percept)

  # The stream is threaded through the policy (`docs/monty-bugs.md` §2.5).
  defp sample(%__MODULE__{} = policy, ctx) do
    rng = ActionSampler.stream(policy.action_sampler, policy.rng, ctx)
    {action, rng} = ActionSampler.sample(policy.action_sampler, policy.agent_id, rng)

    {action, %{policy | rng: rng}}
  end

  @doc "Starts the next episode with nothing to step back to."
  @impl true
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = policy), do: %{policy | rng: nil, undo_action: nil}

  @doc "The action it would step back with, which is all it knows."
  @impl true
  @spec state_dict(t()) :: map()
  def state_dict(%__MODULE__{} = policy), do: %{undo_action: policy.undo_action}
end
