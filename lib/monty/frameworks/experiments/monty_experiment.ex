defmodule Monty.Frameworks.Experiments.MontyExperiment do
  @moduledoc """
  `tbp/monty/frameworks/experiments/monty_experiment.py::MontyExperiment`.

  Monty's base experiment owns the loop an episode runs: step the model against
  the environment, then ask the recognition policy whether the episode is over,
  and stop at whichever comes first.

      count = RecognitionCounter(mode=self.experiment_mode)
      while not self._recognition_complete(count):
          actions = self.run_step(ctx, count.step, actions)
          count.step += 1

  `run_episode_steps/2` is that loop and nothing else. What a step *is* — the
  interface stepping the world with the last actions, the model stepping on what
  came back, the counter counting only the steps an LM actually saw — is
  `Monty.Studio.Run`, and what "done" is, is the experiment's recognition policy,
  read by `Run.finished?/1`. Neither is repeated here: the experiment is handed a
  step and a finished test, which is how it owns the loop without owning the
  studio's records, its pubsub or its clock.

  ## Where it deliberately differs

  Monty's loop ends in one of two ways — the policy said done, or the loop ran out
  of steps — and anything else raises across the epoch. A studio run also has a
  caller who may ask it to stop, and a step that dies, and a page has to be able
  to say which of those happened rather than wait for ever. So the loop is given a
  `:stopped?` test, and answers `{:crashed, step, reason}` for a step that
  reported a failure instead of throwing.

  ## What is not here

  Epochs. Monty's `run_epoch` walks the object list and brackets each episode with
  `pre_episode`/`post_episode`, and `MontySupervisedObjectPretrainingExperiment`
  runs training epochs; a studio run is one episode of one experiment today, so
  writing an epoch loop here would be inventing behaviour rather than porting it.
  """

  @typedoc "How an episode ended."
  @type outcome :: :finished | :stopped | {:crashed, non_neg_integer(), term()}

  @typedoc """
  What the experiment needs of the thing it is driving.

    * `:step` — one step, answering the episode's report (`{:ok, info, state}`) or
      why it could not be taken (`{:error, reason}`);
    * `:finished?` — the experiment's own answer to "is this episode over", which
      is its recognition policy;
    * `:stopped?` — whether the caller has asked the run to stop.
  """
  @type callbacks(state, info) :: %{
          step: (state -> {:ok, info, state} | {:error, term()}),
          finished?: (state -> boolean()),
          stopped?: (-> boolean())
        }

  @doc """
  Steps until the policy says the episode is done, or the caller stops it.

  Answers the outcome, the reports of the steps the episode took — newest first,
  as they were collected — and the state the loop left behind. Monty's version
  answers the step count; a studio run needs the reports and the outcome too,
  because each one is shown while the run happens and the ending is what the
  record keeps.
  """
  @spec run_episode_steps(state, callbacks(state, info)) :: {outcome(), [info], state}
        when state: term(), info: term()
  def run_episode_steps(state, %{step: step, finished?: finished?, stopped?: stopped?}) do
    loop(state, step, finished?, stopped?, [])
  end

  defp loop(state, step, finished?, stopped?, infos) do
    cond do
      # A stop lands between steps: the step being asked for is not taken, which
      # is what makes a stopped run a run that ended at a step boundary.
      stopped?.() -> {:stopped, infos, state}
      finished?.(state) -> {:finished, infos, state}
      true -> advance(state, step, finished?, stopped?, infos)
    end
  end

  defp advance(state, step, finished?, stopped?, infos) do
    case step.(state) do
      {:ok, info, state} -> loop(state, step, finished?, stopped?, [info | infos])
      {:error, reason} -> {{:crashed, length(infos), reason}, infos, state}
    end
  end
end
