defmodule Monty.Frameworks.Models.MotorPolicySelectors.AnsweringPolicy do
  @moduledoc """
  A motor policy that answers what it was told, in order, and keeps the goals it
  was asked about.

  Monty's selector cases hand a selector `Mock()` policies and then read the
  mock's call log and its re-set `return_value`; a policy here is a struct whose
  module answers, so the log is a field — `goals` — and the answers are a list the
  policy walks down, which is the same as re-setting the mock between calls.
  """

  alias Monty.Frameworks.Models.MotorPolicies.MotorPolicyResult

  defstruct results: [], goals: []

  @typedoc "A policy with the answers it has left, and the goals it has been asked about."
  @type t :: %__MODULE__{results: [MotorPolicyResult.t()], goals: [term()]}

  @doc "A policy whose answers are `results`, in that order."
  @spec new([MotorPolicyResult.t()]) :: t()
  def new(results) when is_list(results) and results != [], do: %__MODULE__{results: results}

  @doc "Answers with the next result it has, and remembers the goal it was asked about."
  @spec call(t(), term(), term(), term(), term(), term()) :: {MotorPolicyResult.t(), t()}
  def call(
        %__MODULE__{results: [result | rest]} = policy,
        _ctx,
        _observations,
        _state,
        _percept,
        goal
      ) do
    {result, %{policy | results: rest, goals: policy.goals ++ [goal]}}
  end

  @doc "Starts the next episode: the goals are forgotten, the answers are not."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = policy), do: %{policy | goals: []}

  @doc "What this policy did, for whoever reads the run afterwards."
  @spec state_dict(t()) :: map()
  def state_dict(%__MODULE__{} = policy), do: %{goals: policy.goals}
end
