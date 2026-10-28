defmodule Monty.Frameworks.Models.MotorPolicies.MotorPolicy do
  @moduledoc """
  The scaffold every motor policy is built on.

  Mirrors `tbp/monty/frameworks/models/motor_policies.py::MotorPolicy`, which is
  abstract and says only what a policy has to be able to do: act on a step,
  start an episode over, and say what it knows.

  Monty's `load_state_dict` is absent: loading a memento is how a *checkpoint*
  restores a run, and this port's checkpoints are the studio's own records.
  `fixme_provide_motor_system` is absent for the reason given in
  `...MotorPolicySelectors.MotorPolicySelector` — the flag travels in the result.
  """

  @doc """
  The actions to take, whether learning modules should sit this step out, and
  the policy as it now stands.
  """
  @callback call(
              t(),
              ctx :: Monty.Context.t(),
              observations :: map() | nil,
              state :: Monty.Frameworks.Models.MotorSystemState.t(),
              percept :: Monty.Cmp.Message.t() | nil,
              goal :: Monty.Cmp.Goal.t() | nil
            ) :: {Monty.Frameworks.Models.MotorPolicies.MotorPolicyResult.t(), t()}

  @doc "Starts the next episode: whatever the policy learned about this one goes."
  @callback reset(t()) :: t()

  @doc "What the policy recorded, for a run that wants to be read afterwards."
  @callback state_dict(t()) :: map()

  @type t :: struct()
end
