defmodule Monty.Frameworks.Models.MotorPolicySelectors do
  @moduledoc """
  Choosing which policy drives the body on a given step.

  Mirrors `tbp/monty/frameworks/models/motor_policy_selectors.py`, which holds
  the selector interface and the two selectors Monty ships:

    * `...MotorPolicySelectors.MotorPolicySelector` — **ported**: the interface,
      `call/5` answering a `MotorPolicyResult` and the selector it updated;
    * `...MotorPolicySelectors.SinglePolicySelector` — **ported**: one policy,
      given the highest-confidence goal of the step;
    * `...MotorPolicySelectors.DistantPolicySelector` — **ported**: routes goals
      that name an object to a jump policy, goals from a sensor module to a
      look-at policy, and everything else to a default.

  A policy here is a five-argument function — `(ctx, observations, state,
  percept, goal)` — because that is the whole of what Monty's `__call__` is.
  Holding the function rather than the class keeps a selector testable without a
  policy, and lets a policy be any module's function that answers a
  `MotorPolicyResult`.
  """

  alias Monty.Cmp.Goal
  alias Monty.Frameworks.Models.MotorPolicies

  @doc """
  The goal with the highest confidence, or the first of equal ones.

  Monty sorts by confidence descending and takes the head, which for equal
  confidences is the first: a stable sort is the whole of the tie-break. The
  goals must not be empty — a step with no goals has nothing to choose between,
  and the selectors ask that question before asking this one.
  """
  @spec highest_confidence_goal([Goal.t()]) :: Goal.t()
  def highest_confidence_goal(goals), do: Enum.max_by(goals, & &1.confidence)

  @doc """
  The selector a config describes.

      policy_selector:
        _target_: tbp.monty.frameworks.models.motor_policy_selectors.DistantPolicySelector
        jump_to_goal:
          _target_: ...JumpToGoal
        look_at_goal:
          _target_: ...LookAtGoal
        default:
          _target_: ...InformedPolicyRandomWalk

  A selector's policies are configs themselves, so they are built the same way
  it is — which is what makes the config the description of the body rather
  than a list of names to look up.
  """
  @spec from_config(map()) ::
          Monty.Frameworks.Models.MotorPolicySelectors.MotorPolicySelector.t()
  def from_config(%{"_target_" => _target} = config) do
    options =
      config
      |> Map.delete("_target_")
      |> Enum.map(&selector_option/1)

    Monty.Config.Target.class!(config).new(options)
  end

  defp selector_option({key, policy_config})
       when key in ~w(policy jump_to_goal look_at_goal default),
       do: {String.to_existing_atom(key), MotorPolicies.from_config(policy_config)}

  defp selector_option({key, _value}),
    do: raise(ArgumentError, "a policy selector takes no #{inspect(key)}")
end
