defmodule Monty.Frameworks.Experiments.PretrainingExperiments.MontySupervisedObjectPretrainingExperiment do
  @moduledoc """
  `tbp/monty/frameworks/experiments/pretraining_experiments.py::MontySupervisedObjectPretrainingExperiment`.

  Run exploratory steps and tell the model the object and the pose.

  A pretraining episode does not recognise anything, so there is nothing to
  match: the experiment knows which object it put in front of the agent and
  where, runs the episode as exploration, and states that answer to the modules
  at the end — which is the moment the observations become a graph. Monty's own
  comment calls it "not really an experiment … more a pretraining step to
  generate models that can then be loaded at the beginning of an experiment",
  and that is what this is here too.

  ## The two hooks it adds

  `pre_episode/4` gives the episode its target and, when every module is
  supervised, switches the model to exploring: a step that will be told the
  answer does not have to look for it.

  `post_episode/4` states the answer (`Monty.Studio.Run.supervise/1`) *after*
  the steps have written their own statistics and *before* the memory is
  written, which is the order Monty's `post_episode` has — a supervised
  conclusion written earlier would be overwritten by the next matching step, and
  one written later would arrive after the graph it was meant to build.

  ## What it does not do

  Monty's `evaluate/1` warns and does nothing, so a run of this class has no
  evaluation phase; `do_eval: false` in the config says the same thing before a
  run starts, and the phase plan is built from it. Its `__init__` also appends
  `pretrained` to the output directory, so a pretrained model is filed away from
  the logs; here a run's own memory is filed under its own directory and the
  release it belongs to (`Monty.Studio.Jobs.Run.keep_memory/4`), which is that
  decision made where the writing happens.
  """

  alias Monty.Frameworks.Experiments.MontyExperiment
  alias Monty.Studio.Run

  @doc """
  Monty's `train()`/`evaluate()`: every epoch, through this class's `pre_episode`.

  In Python the loops are inherited and the hooks are overridden; here the loops
  are `MontyExperiment`'s and the overrides are named in the callbacks they are
  given.
  """
  @spec run_epochs(state, MontyExperiment.callbacks(state, info)) ::
          {MontyExperiment.outcome(), [MontyExperiment.episode_result()], state}
        when state: term(), info: term()
  def run_epochs(state, callbacks) do
    MontyExperiment.run_epochs(state, Map.put(callbacks, :experiment, __MODULE__))
  end

  @doc "One epoch, through this class's `pre_episode/4`."
  @spec run_epoch(state, MontyExperiment.callbacks(state, info)) ::
          {MontyExperiment.outcome(), [MontyExperiment.episode_result()], state}
        when state: term(), info: term()
  def run_epoch(state, callbacks) do
    MontyExperiment.run_epoch(state, Map.put(callbacks, :experiment, __MODULE__))
  end

  @doc """
  Monty's `pre_episode`: the episode's target, then exploring.

  The target is stated with no semantic labels, which is what Monty's
  pretraining does (`self.model.fixme_set_ground_truth(self.env_interface.
  primary_target)` takes one argument): the object under the patch is not being
  named this episode, and a stepwise target would be a recognition experiment's
  question.
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
      {:ok, state |> state_the_target() |> explore_when_all_supervised()}
    end
  end

  @doc """
  Monty's `post_episode`: the answer the experiment states, then the episode ends.

  The order is the whole of it — see the module docstring. The memory is written
  by whatever the callbacks do next (`Run.next_memories/3`), so the answer has
  to be in place before this returns.
  """
  @spec post_episode(
          map(),
          MontyExperiment.outcome(),
          [term()],
          MontyExperiment.callbacks(term(), term())
        ) ::
          term()
  def post_episode(%{run: run} = state, outcome, infos, callbacks) do
    {:ok, supervised} = Run.supervise(run)

    MontyExperiment.post_episode(%{state | run: supervised}, outcome, infos, callbacks)
  end

  defp state_the_target(%{run: run} = state) do
    :ok = Run.set_ground_truth(run, semantic_id_to_label: %{})
    state
  end

  # Monty's `switch_to_exploratory_step`, taken when every module is told the
  # answer: no step needs to match, so the episode explores and saves the work.
  # A module left unsupervised still has to match, so the episode stays as it is.
  defp explore_when_all_supervised(%{run: run} = state) do
    if every_module_supervised?(run.setup) do
      :ok = run.model.switch_to_exploratory_step(run.model_id)
    end

    state
  end

  defp every_module_supervised?(setup) do
    supervised = setup |> Monty.Studio.Setup.supervised_ids() |> MapSet.new()
    wired = setup.learning_modules |> Enum.map(& &1.id) |> MapSet.new()

    supervised == wired
  end
end
