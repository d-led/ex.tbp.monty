defmodule Monty.Frameworks.Models.MotorPolicySelectors.SinglePolicySelector do
  @moduledoc """
  One policy, given the goal the rest of the run believes in most.

  Mirrors `tbp/monty/frameworks/models/motor_policy_selectors.py::SinglePolicySelector`.
  Several learning modules can propose several goals in one step, and a body can
  only pursue one: this takes the most confident and hands it over, recording
  which goal each step was given so a run can be read afterwards.

  The policy is a five-argument function, and the last thing it is given is the
  chosen goal or `nil` — `nil` on a step where nothing proposed anything, which
  a surface policy reads as "carry on exploring".
  """

  @behaviour Monty.Frameworks.Models.MotorPolicySelectors.MotorPolicySelector

  alias Monty.Frameworks.Models.MotorPolicies.MotorPolicyResult
  alias Monty.Frameworks.Models.MotorPolicySelectors

  @enforce_keys [:policy]
  defstruct policy: nil, selected_goals: []

  @typedoc """
  What a policy is here: a struct and the module named after it, so the step
  asks the policy's own module — as `DistantPolicySelector` does, and as Monty's
  `MotorPolicy.__call__` does.
  """
  @type policy :: Monty.Frameworks.Models.MotorPolicies.MotorPolicy.t()

  @type t :: %__MODULE__{policy: policy(), selected_goals: [Monty.Cmp.Goal.t() | nil]}

  @doc """
  A selector that always asks `policy`.

  `:policy` is required. `:selected_goals` is the log, and an experiment that
  starts mid-run can hand one over.
  """
  @spec new(keyword()) :: t()
  def new(options) do
    %__MODULE__{
      policy: Keyword.fetch!(options, :policy),
      selected_goals: Keyword.get(options, :selected_goals, [])
    }
  end

  @doc """
  Asks the policy about the most confident goal of this step, and records it.

  With no goals the policy is still called, with `nil`: standing still is a
  policy decision too, and a surface policy explores when nothing is asked of
  it.
  """
  @impl true
  @spec call(
          t(),
          Monty.Context.t(),
          term(),
          Monty.Frameworks.Models.MotorSystemState.t(),
          Monty.Cmp.Message.t() | nil,
          [Monty.Cmp.Goal.t()]
        ) :: {MotorPolicyResult.t(), t()}
  def call(%__MODULE__{} = selector, ctx, observations, state, percept, goals) do
    goal = goal_to_pursue(goals)

    {result, policy} =
      selector.policy.__struct__.call(selector.policy, ctx, observations, state, percept, goal)

    {result, %{selector | policy: policy, selected_goals: selector.selected_goals ++ [goal]}}
  end

  defp goal_to_pursue([]), do: nil
  defp goal_to_pursue(goals), do: MotorPolicySelectors.highest_confidence_goal(goals)

  @doc """
  Starts the next episode: the policy starts over, and the record is cleared.

  Monty's `SinglePolicySelector.reset` resets its policy too, and it has to: a
  policy mid-way through a spiral or a jump would otherwise carry it into the
  next object.
  """
  @impl true
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = selector) do
    %{
      selector
      | policy: selector.policy.__struct__.reset(selector.policy),
        selected_goals: []
    }
  end

  @doc """
  The policy's own record, and the goals this selector chose.
  """
  @impl true
  @spec state_dict(t()) :: map()
  def state_dict(%__MODULE__{} = selector) do
    %{
      policy: selector.policy.__struct__.state_dict(selector.policy),
      selected_goals: selector.selected_goals
    }
  end
end
