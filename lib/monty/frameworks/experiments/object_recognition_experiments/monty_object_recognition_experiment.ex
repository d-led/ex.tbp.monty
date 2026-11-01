defmodule Monty.Frameworks.Experiments.ObjectRecognitionExperiments.MontyObjectRecognitionExperiment do
  @moduledoc """
  `tbp/monty/frameworks/experiments/object_recognition_experiments.py::MontyObjectRecognitionExperiment`.

  The experiment an object-recognition config names. Its whole body in Monty is
  one hook — `pre_episode` — and what that hook adds to `MontyExperiment`'s is one
  sentence: the episode's primary target, and the scene's semantic ids, are handed
  to the model, so a step can say *which* object was under the patch rather than
  only that there was one. Everything else it has is inherited.

  So this module is small on purpose, and it is not a façade: the epoch a run of
  such a config takes is driven through it (`Setup.experiment_class/1`), which is
  what makes the sentence true of a run rather than of a class nobody calls.

  ## Where the behaviour actually lives

  The interface's half of `pre_episode` — ask the world for an episode, position
  the agent, reset the sensors — is `Monty.Studio.Run.start/2`, because a studio
  run *is* an episode of this experiment and its state is a value. The
  experiment's half is `Monty.Studio.Run.set_ground_truth/1`, called from here in
  Monty's order: the base hook first, then the ground truth.
  """

  alias Monty.Frameworks.Experiments.MontyExperiment

  @doc """
  Monty's `run_epoch`, with this class's `pre_episode/4` for every episode.

  In Python the epoch loop is inherited and the hook is overridden; here the loop
  is `MontyExperiment.run_epoch/2` and the override is named in the callbacks it
  is given, which is the same arrangement said in a language that has no
  inheritance.
  """
  @spec run_epoch(state, MontyExperiment.callbacks(state, info)) ::
          {MontyExperiment.outcome(), [MontyExperiment.episode_result()], state}
        when state: term(), info: term()
  def run_epoch(state, callbacks) do
    MontyExperiment.run_epoch(state, Map.put(callbacks, :experiment, __MODULE__))
  end

  @doc "Monty's `evaluate()`: every rotation, through this class's `pre_episode/4`."
  @spec run_epochs(state, MontyExperiment.callbacks(state, info)) ::
          {MontyExperiment.outcome(), [MontyExperiment.episode_result()], state}
        when state: term(), info: term()
  def run_epochs(state, callbacks) do
    MontyExperiment.run_epochs(state, Map.put(callbacks, :experiment, __MODULE__))
  end

  @doc """
  Monty's `pre_episode`: the base hook, then the episode's ground truth.

  The callbacks carry both halves, because the run that a studio experiment is
  stepped in is not this module's value. A caller that supplies no ground truth
  gets the base hook alone — which is `MontyExperiment`, and is what a world
  without semantics leaves to say: nothing.
  """
  @spec pre_episode(
          map(),
          non_neg_integer(),
          String.t() | nil,
          MontyExperiment.callbacks(term(), term())
        ) ::
          {:ok, term()} | {:error, term()}
  def pre_episode(state, index, object, callbacks) do
    with {:ok, state} <- MontyExperiment.pre_episode(state, index, object, callbacks) do
      ground_truth(state, callbacks)
    end
  end

  defp ground_truth(state, %{ground_truth: ground_truth}) when is_function(ground_truth, 1),
    do: ground_truth.(state)

  defp ground_truth(state, _callbacks), do: {:ok, state}
end
