defmodule Monty.Test.RecordingPolicy do
  @moduledoc """
  A policy that answers a fixed result and says what it was asked about.

  A selector's job is to choose *which* policy acts and what to ask it; this
  double makes that answerable without a policy that computes anything.
  """

  @behaviour Monty.Frameworks.Models.MotorPolicies.MotorPolicy

  defstruct actions: [],
            status: :idle,
            motor_only_step: false,
            telemetry: nil,
            asked_about: [],
            resets: 0

  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{
      actions: Keyword.get(options, :actions, []),
      status: Keyword.get(options, :status, :idle),
      motor_only_step: Keyword.get(options, :motor_only_step, false),
      telemetry: Keyword.get(options, :telemetry)
    }
  end

  @type t :: %__MODULE__{
          actions: [term()],
          status: atom(),
          motor_only_step: boolean(),
          telemetry: term(),
          asked_about: [term()],
          resets: non_neg_integer()
        }

  @impl true
  def call(%__MODULE__{} = policy, _ctx, _observations, _state, _percept, goal) do
    result = %Monty.Frameworks.Models.MotorPolicies.MotorPolicyResult{
      actions: policy.actions,
      status: policy.status,
      motor_only_step: policy.motor_only_step,
      telemetry: policy.telemetry
    }

    {result, %{policy | asked_about: policy.asked_about ++ [goal]}}
  end

  @impl true
  def reset(%__MODULE__{} = policy), do: %{policy | asked_about: [], resets: policy.resets + 1}

  @impl true
  def state_dict(%__MODULE__{} = policy), do: %{asked_about: policy.asked_about}
end
