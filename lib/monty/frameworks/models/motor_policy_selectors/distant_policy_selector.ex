defmodule Monty.Frameworks.Models.MotorPolicySelectors.DistantPolicySelector do
  @moduledoc """
  Three policies, chosen by who proposed the goal.

  Mirrors `tbp/monty/frameworks/models/motor_policy_selectors.py::DistantPolicySelector`,
  the selector a distant agent runs. A distant agent can be asked for three
  different kinds of step in one run, and the sender of the goal is what says
  which:

    * a **learning module** proposed it (`:gsg`): the module wants a hypothesis
      tested, so the agent teleports — `JumpToGoal` — and spends the following
      step judging where it landed;
    * a **sensor module** proposed it (`:sm`): the sensor wants to look at
      something, so the agent turns — `LookAtGoal`;
    * **nobody** proposed anything: the default policy wanders.

  A jump in flight takes priority over everything else, including a new
  learning-module goal, because the agent is half-way through an experiment it
  has to finish: `JumpToGoal` is asked first, and only if it has nothing to say
  does the step fall through to the other two. Of each kind, the most confident
  goal is the one pursued.

  ## Why it holds policies rather than functions

  `SinglePolicySelector` holds its policy as a five-argument function, because a
  step is all it needs. This one needs more: it reads the jump's `status` to know
  whether a jump is in flight, and it resets and reports on all three policies.
  So it holds the three policy structs and threads each one's state, which is
  Monty's shape too — its selector holds policy objects and calls their methods.
  """

  @behaviour Monty.Frameworks.Models.MotorPolicySelectors.MotorPolicySelector

  alias Monty.Cmp.Goal
  alias Monty.Frameworks.Models.MotorPolicies.{JumpToGoal, MotorPolicyResult}
  alias Monty.Frameworks.Models.MotorPolicySelectors
  alias Monty.Frameworks.Models.Salience.MotorPolicy.LookAtGoal

  @enforce_keys [:jump_to_goal, :look_at_goal, :default]
  defstruct jump_to_goal: nil,
            look_at_goal: nil,
            default: nil,
            is_jumping: false,
            selected_policies: [],
            selected_goals: []

  @type t :: %__MODULE__{
          jump_to_goal: JumpToGoal.t(),
          look_at_goal: LookAtGoal.t(),
          default: Monty.Frameworks.Models.MotorPolicies.MotorPolicy.t(),
          is_jumping: boolean(),
          selected_policies: [module()],
          selected_goals: [Goal.t() | nil]
        }

  @doc """
  A selector over `:jump_to_goal`, `:look_at_goal` and `:default`.

  All three are required: a selector with a missing policy would have to invent
  a step, and inventing one is what the default policy is for.
  """
  @spec new(keyword()) :: t()
  def new(options) do
    %__MODULE__{
      jump_to_goal: Keyword.fetch!(options, :jump_to_goal),
      look_at_goal: Keyword.fetch!(options, :look_at_goal),
      default: Keyword.fetch!(options, :default)
    }
  end

  @doc """
  The step, from whichever policy the goals point at.

  A jump in flight is judged first; if that verdict is "no actions", the step
  carries on to the other two rather than ending, because there is nothing left
  to do about the jump and everything still to do about the goals.
  """
  @impl true
  @spec call(
          t(),
          Monty.Context.t(),
          map() | nil,
          Monty.Frameworks.Models.MotorSystemState.t(),
          Monty.Cmp.Message.t() | nil,
          [Goal.t()]
        ) :: {MotorPolicyResult.t(), t()}
  def call(%__MODULE__{} = selector, ctx, observations, state, percept, goals) do
    learning_module_goals = goals_of_type(goals, :gsg)

    case settle_jump(selector, ctx, observations, state, percept, learning_module_goals) do
      {:done, result, selector} ->
        {result, selector}

      {:continue, selector} ->
        pursue(selector, ctx, observations, state, percept, learning_module_goals, goals)
    end
  end

  # -- a jump already in flight ----------------------------------------------

  defp settle_jump(
         %__MODULE__{is_jumping: false} = selector,
         _ctx,
         _obs,
         _state,
         _percept,
         _goals
       ),
       do: {:continue, selector}

  defp settle_jump(selector, ctx, observations, state, percept, learning_module_goals) do
    goal = most_confident(learning_module_goals)

    {%MotorPolicyResult{actions: actions, status: status} = result, jump_to_goal} =
      step(selector.jump_to_goal, ctx, observations, state, percept, goal)

    selector = %{
      selector
      | jump_to_goal: jump_to_goal,
        is_jumping: status == :in_progress
    }

    if actions == [] do
      {:continue, selector}
    else
      {:done, result, record(selector, JumpToGoal, goal)}
    end
  end

  # -- choosing what to do ---------------------------------------------------

  defp pursue(selector, ctx, observations, state, percept, learning_module_goals, goals) do
    cond do
      learning_module_goals != [] ->
        goal = most_confident(learning_module_goals)
        jump(selector, ctx, observations, state, percept, goal)

      goals_of_type(goals, :sm) != [] ->
        goal = most_confident(goals_of_type(goals, :sm))
        look(selector, ctx, observations, state, percept, goal)

      true ->
        wander(selector, ctx, observations, state, percept)
    end
  end

  defp jump(selector, ctx, observations, state, percept, goal) do
    {result, jump_to_goal} =
      step(selector.jump_to_goal, ctx, observations, state, percept, goal)

    selector = %{
      selector
      | jump_to_goal: jump_to_goal,
        is_jumping: result.status == :in_progress
    }

    {result, record(selector, JumpToGoal, goal)}
  end

  defp look(selector, ctx, observations, state, percept, goal) do
    {result, look_at_goal} =
      step(selector.look_at_goal, ctx, observations, state, percept, goal)

    {result,
     record(%{selector | look_at_goal: look_at_goal, is_jumping: false}, LookAtGoal, goal)}
  end

  defp wander(selector, ctx, observations, state, percept) do
    {result, default} = step(selector.default, ctx, observations, state, percept, nil)

    {result, record(%{selector | default: default, is_jumping: false}, default.__struct__, nil)}
  end

  # Each policy answers with itself, as every step in this port does; the
  # selector puts the answer back where it came from.
  defp step(policy, ctx, observations, state, percept, goal) do
    policy.__struct__.call(policy, ctx, observations, state, percept, goal)
  end

  defp goals_of_type(goals, type), do: Enum.filter(goals, &(&1.sender_type == type))

  defp most_confident([]), do: nil
  defp most_confident(goals), do: MotorPolicySelectors.highest_confidence_goal(goals)

  defp record(%__MODULE__{} = selector, policy, goal) do
    %{
      selector
      | selected_policies: selector.selected_policies ++ [policy],
        selected_goals: selector.selected_goals ++ [goal]
    }
  end

  # -- what it remembers ----------------------------------------------------

  @doc """
  Starts the next episode: every policy starts over, and the record is cleared.
  """
  @impl true
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = selector) do
    %{
      selector
      | jump_to_goal: JumpToGoal.reset(selector.jump_to_goal),
        look_at_goal: LookAtGoal.reset(selector.look_at_goal),
        default: selector.default.__struct__.reset(selector.default),
        is_jumping: false,
        selected_policies: [],
        selected_goals: []
    }
  end

  @doc """
  Each policy's own record, keyed by which policy it is.

  Monty answers the same shape, and the same reason applies: what a run wants to
  read afterwards is the jump that was in flight, not a summary of it.
  """
  @impl true
  @spec state_dict(t()) :: map()
  def state_dict(%__MODULE__{} = selector) do
    %{
      jump_to_goal: JumpToGoal.state_dict(selector.jump_to_goal),
      look_at_goal: LookAtGoal.state_dict(selector.look_at_goal),
      default: selector.default.__struct__.state_dict(selector.default)
    }
  end
end
