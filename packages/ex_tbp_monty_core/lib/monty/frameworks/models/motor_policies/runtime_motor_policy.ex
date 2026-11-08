defmodule Monty.Frameworks.Models.MotorPolicies.RuntimeMotorPolicy do
  @moduledoc """
  What the runtime asks a policy: given this step, what should move?

  Mirrors `tbp/monty/frameworks/models/motor_policies.py::RuntimeMotorPolicy`, a
  protocol with one method. The goal is the one the selector chose, or `nil` on
  a step where nothing was proposed.
  """

  alias Monty.Cmp.{Goal, Message}
  alias Monty.Context
  alias Monty.Frameworks.Models.MotorPolicies.MotorPolicyResult
  alias Monty.Frameworks.Models.MotorSystemState

  @doc """
  The actions to take, whether learning modules should sit this step out, and
  the policy as it now stands.
  """
  @callback call(
              t(),
              ctx :: Context.t(),
              observations :: map() | nil,
              state :: MotorSystemState.t(),
              percept :: Message.t() | nil,
              goal :: Goal.t() | nil
            ) :: {MotorPolicyResult.t(), t()}

  @type t :: struct()
end
