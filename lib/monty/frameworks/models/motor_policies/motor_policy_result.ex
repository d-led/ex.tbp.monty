defmodule Monty.Frameworks.Models.MotorPolicies.MotorPolicyResult do
  @moduledoc """
  What one call to a motor policy decided: the actions, and how finished it is.

  Mirrors `tbp/monty/frameworks/models/motor_policies.py::MotorPolicyResult`.
  `motor_only_step` says the learning modules should be skipped this step — a
  policy that is only turning or moving has nothing for them to match — and is
  how a policy affects the run without reaching into it. `telemetry` is the
  surface policy's own record of why it chose what it chose, kept because there
  is nowhere else for it to go yet, as Monty says of its own.
  """

  alias Monty.Frameworks.Models.MotorPolicies.PolicyStatus

  defstruct actions: [], motor_only_step: false, telemetry: nil, status: :ready

  @type action :: term()

  @type t :: %__MODULE__{
          actions: [action()],
          motor_only_step: boolean(),
          telemetry: term(),
          status: PolicyStatus.t()
        }

  @doc """
  A result with nothing decided: no actions, and the policy ready for more.

  Monty's conservative defaults, so a policy only has to say what it did.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}
end
