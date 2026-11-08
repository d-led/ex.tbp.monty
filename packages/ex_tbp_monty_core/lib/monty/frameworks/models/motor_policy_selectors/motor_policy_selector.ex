defmodule Monty.Frameworks.Models.MotorPolicySelectors.MotorPolicySelector do
  @moduledoc """
  The motor system's question to a selector: given this step, what should move?

  Mirrors `tbp/monty/frameworks/models/motor_policy_selectors.py::MotorPolicySelector`,
  which joins Monty's runtime interface and its experiment interface into one.
  A selector decides *which* policy acts — one policy always, or one of several
  depending on the goals that arrived — and answers the same
  `MotorPolicyResult` whatever it chose.

  Two differences from Monty, both forced by values rather than pointers:

    * the selector is handed back along with the result, because choosing is
      also recording — Monty appends the chosen goal to itself — and a struct
      cannot be changed in place;
    * there is no `fixme_provide_motor_system`. Monty hands the selector the
      motor system only so the chosen policy can set `motor_only_step` on it;
      here that flag travels in the result, so the call and its name both go.
  """

  alias Monty.Cmp.{Goal, Message}
  alias Monty.Context
  alias Monty.Frameworks.Models.MotorPolicies.MotorPolicyResult
  alias Monty.Frameworks.Models.MotorSystemState

  @doc """
  The actions to take this step, whether learning modules should sit it out, and
  the selector as it now stands.
  """
  @callback call(
              t(),
              ctx :: Context.t(),
              observations :: map() | nil,
              state :: MotorSystemState.t(),
              percept :: Message.t() | nil,
              goals :: [Goal.t()]
            ) :: {MotorPolicyResult.t(), t()}

  @doc "Forgets everything the selector knows about the episode so far."
  @callback reset(t()) :: t()

  @doc "What the selector recorded, for a run that wants to be read afterwards."
  @callback state_dict(t()) :: map()

  @type t :: struct()
end
