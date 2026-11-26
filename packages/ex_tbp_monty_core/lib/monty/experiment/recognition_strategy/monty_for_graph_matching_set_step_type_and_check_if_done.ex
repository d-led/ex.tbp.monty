defmodule Monty.Experiment.RecognitionStrategy.MontyForGraphMatchingSetStepTypeAndCheckIfDone do
  @moduledoc """
  Monty's step-type and terminal-condition rules, written as a recognition policy.

  Mirrors
  `tbp.monty/experiment/recognition_strategy.py::MontyForGraphMatchingSetStepTypeAndCheckIfDone`,
  which is `MontyForGraphMatching._set_step_type_and_check_if_done` moved out of
  the model and satisfied with the numbers that used to sit on `monty_config`.
  The shipped termination groups name it with three of them —
  `min_train_steps`, `min_eval_steps`, `num_exploratory_steps` — and a match
  criterion of its own.

  ## What it decides

  A matching step ends an episode only if a learning module processed it *and*
  the modules have reached a terminal state:

    * every module concluded `no_match` — there is nothing left to agree on, so
      the episode is over whatever the step minimums say;
    * past the mode's minimum of matching steps, the criterion is asked over the
      modules' terminal states — and when it is satisfied a training episode
      switches to exploring while an evaluation one ends. An evaluation ends
      only once `matching_steps > min_eval_steps`.

  An exploratory step ends an episode once `exploring_steps` has passed
  `num_exploratory_steps`, again only on a step a module processed.

  ## The two readings Monty takes that a policy here is given

  Monty's `__call__` asks every module to update its terminal condition
  (`lm.update_terminal_condition()`) and reads the buffer to ask whether the
  step was processed (`lm.buffer.get_last_obs_processed()`). A policy in this
  port is pure (`docs/monty-differences.md` §2.17), so both arrive in the model
  view: `processed?` is the model's `check_if_any_lms_updated` for the step just
  taken, and `terminal_states` are the modules' answers after the model asked
  them to settle — which `Monty.Runtime.Step` does at the end of a processed
  step past the minimum (`docs/monty-differences.md` §2.40).
  """

  alias Monty.Experiment.RecognitionStrategy.RecognitionResult

  @options [:match_criterion, :min_train_steps, :min_eval_steps, :num_exploratory_steps]

  @doc """
  The policy with its criterion and its three step minimums.

  Monty's constructor takes all four; a config that omits one is refused here
  rather than taking a default that no config asked for.
  """
  @spec new(keyword()) :: {:ok, {module(), map()}} | {:error, String.t()}
  def new(options) do
    case Keyword.take(options, @options) do
      taken when length(taken) == length(@options) ->
        {:ok, {__MODULE__, Map.new(taken)}}

      _missing ->
        {:error, "a step-type policy needs #{Enum.join(@options, ", ")}"}
    end
  end

  @doc "The decision, from the model's readings and the episode's counters."
  @spec call(map(), Monty.Experiment.RecognitionStrategy.RecognitionContext.t(), map()) ::
          RecognitionResult.t()
  def call(%{is_exploring: true} = model, counter, state),
    do: after_exploratory_step(model, counter, state)

  def call(model, counter, state), do: after_matching_step(model, counter, state)

  defp after_exploratory_step(%{processed?: true}, counter, state) do
    if counter.exploring_steps >= state.num_exploratory_steps,
      do: %RecognitionResult{is_done: true},
      else: %RecognitionResult{}
  end

  defp after_exploratory_step(_model, _counter, _state), do: %RecognitionResult{}

  defp after_matching_step(%{processed?: true} = model, counter, state) do
    if terminal_conditions?(model, counter, state) do
      %RecognitionResult{
        is_done: counter.mode == :eval and counter.matching_steps > state.min_eval_steps,
        time_out_lms: true,
        start_exploring: counter.mode == :train
      }
    else
      %RecognitionResult{}
    end
  end

  defp after_matching_step(_model, _counter, _state), do: %RecognitionResult{}

  # Monty's `_check_terminal_conditions`, in its order: nothing to agree on,
  # then the mode's minimum of matching steps, then the criterion.
  defp terminal_conditions?(model, counter, state) do
    cond do
      all_modules_gave_up?(model) -> true
      not exceeded_min_steps?(model, counter, state) -> false
      true -> criterion_matched?(model, state)
    end
  end

  defp all_modules_gave_up?(%{conclusions: conclusions}),
    do: conclusions != [] and Enum.all?(conclusions, &(&1 == :no_match))

  defp criterion_matched?(model, state) do
    {criterion, argument} = state.match_criterion
    criterion.matched?(model.terminal_states, argument)
  end

  # Monty's `_exceeded_min_steps`: strictly past the minimum, and counted in the
  # steps a module processed rather than in timesteps.
  defp exceeded_min_steps?(model, counter, state) do
    if model.is_exploring,
      do: counter.exploring_steps > state.num_exploratory_steps,
      else: counter.matching_steps > min_matching_steps(counter, state)
  end

  defp min_matching_steps(%{mode: :train}, state), do: state.min_train_steps
  defp min_matching_steps(%{mode: :eval}, state), do: state.min_eval_steps
end
