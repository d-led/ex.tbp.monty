defmodule Monty.Frameworks.Models.NoResetEvidenceMatching.MontyForNoResetEvidenceGraphMatching do
  @moduledoc """
  The model an unsupervised-inference run starts: one that is never told an
  episode has ended.

  Mirrors `frameworks/models/no_reset_evidence_matching.py::MontyForNoResetEvidenceGraphMatching`.
  Monty's ordinary model begins an episode by resetting its modules, which
  throws away their hypotheses and the evidence behind them; this one begins an
  episode by resetting the *counters* — the step counts, the terminal states, the
  motor system's place in its policy — and empties the buffers. What the modules
  believe survives, because in the experiment this class was written for the
  object under the sensor changes with no signal announcing it, and the model
  has to discover the change from evidence falling away. It is intended for
  evaluation-only runs against a pretrained model, with Monty in the matching
  phase throughout.

  ## What a run of this class keeps, and what it forgets

  Kept across an object change: the hypothesis space of every module, the
  evidence of each hypothesis, the most likely hypothesis, the goal generator's
  schedule, each sensor's delta-filter memory, the record of what each sensor was
  on at every step (`stepwise_targets_list`), and where the sensor was — which is
  why `NoResetEvidenceGraphLM` remembers that itself.

  Forgotten: the step counters, the modules' conclusions and the objects and
  poses they named, each module's buffer of observations, each sensor's processed
  observations, and the model's `done?`.

  ## One difference from Monty, on purpose

  Monty's class resets *fully* once and skips the full reset afterwards, because
  some of its modules' fields are only initialised by `reset()` and graphs are
  loaded after construction (`__init__`'s comment says so). Neither is true here:
  `EvidenceGraphLM.new/2` ends in `reset_stm/1`, and a learning module is built
  with the memory it will match against, so a module is fully initialised before
  the first episode. The distinction therefore has no work to do, and every
  reset is the partial one — which is also what Monty's first reset amounts to on
  a module that is already initialised.

  ## What is not carried

  Monty's `snapshot/0` and `restore/1` copy the model's `state_dict` so a run can
  be forked and compared. This port has no `state_dict` for a model — the modules
  are processes and the memory they hold travels as a `GraphMemory` — so there is
  nothing here to copy; `docs/training.md` says where a learned memory is written
  instead.
  """

  alias Monty.Runtime.{LearningModuleServer, Model, SensorModuleServer, Step}

  @doc """
  The model as something a supervisor can start.

  Monty's constructor builds the model; here it is `spec` — what the config
  resolved to — and starting it is the runtime's.
  """
  @spec child_spec(map()) :: Supervisor.child_spec()
  def child_spec(spec) do
    spec
    |> Model.child_spec()
    |> Supervisor.child_spec(id: {__MODULE__, spec.model_id})
  end

  @doc """
  `reset/0`, as this class means it: the episode starts again, what the modules
  believe does not.

  Monty's `_reset_terminal_states` (`lm.set_individual_ts(None)`) and
  `_reset_modules_buffers` (`lm.buffer.reset()`, `sm.processed_obs = []`), after
  `reset_episode_steps()` and `switch_to_matching_step()`. The motor system is
  deliberately not reset: Monty's override does not reset it either, and a policy
  that forgot its last action would have to find the object again after every
  object change.
  """
  @spec reset_episode_state(Step.State.t()) :: Step.State.t()
  def reset_episode_state(%Step.State{} = state) do
    state
    |> Step.restart_counters()
    |> Step.exec_learning_modules(&LearningModuleServer.clear_conclusion/1)
    |> Step.exec_learning_modules(&LearningModuleServer.clear_buffers/1)
    |> Step.exec_sensor_modules(&SensorModuleServer.clear_buffers/1)
  end

  @doc """
  `fixme_set_ground_truth`: the object this episode is about, told to the modules
  without emptying their record of what the sensor was on.

  Monty's override writes `lm.primary_target` and `lm.primary_target_rotation_quat`
  itself instead of calling `lm.fixme_reset_ground_truth`, which would clear
  `stepwise_targets_list` — the only record of which object the sensor was on at
  every step of a run that never restarts.
  """
  @spec set_ground_truth_state(Step.State.t(), map() | nil, keyword()) :: Step.State.t()
  def set_ground_truth_state(%Step.State{} = state, primary_target, opts) do
    state
    |> Step.exec_learning_modules(&LearningModuleServer.set_primary_target(&1, primary_target))
    |> Step.put_semantic_id_to_label(opts)
  end

  # -- what every model class answers the same way --------------------------
  #
  # Stepping a model is the runtime's business for every class: the modules are
  # processes, and the coordinator holds the step count. What a class decides is
  # the episode boundary, above.

  @doc "One timestep: what the modules were given and what they made of it."
  @spec step(atom() | String.t(), map(), map(), Monty.Context.t()) :: {:ok, [map()], map()}
  def step(model_id, observations, proprioceptive_state, ctx),
    do: Model.step(model_id, observations, proprioceptive_state, ctx)

  @doc "The coordinator's state, which is where an episode's conclusion lives."
  @spec state(atom() | String.t()) :: Step.State.t()
  def state(model_id), do: Model.state(model_id)

  @doc "Whether the model has concluded this episode."
  @spec done?(atom() | String.t()) :: boolean()
  def done?(model_id), do: Model.done?(model_id)

  @doc "The four things a recognition policy may read off the model."
  @spec status(atom() | String.t()) :: Monty.Experiment.RecognitionStrategy.model()
  def status(model_id), do: Model.status(model_id)

  @doc "Clears short-term memory for a new episode, as this class defines it."
  @spec reset_episode(atom() | String.t()) :: :ok
  def reset_episode(model_id), do: Model.reset_episode(model_id)

  @doc "`MontyBase.set_experiment_mode`: whether this episode trains or evaluates."
  @spec set_experiment_mode(
          atom() | String.t(),
          Monty.Frameworks.Models.AbstractMontyClasses.LearningModule.mode()
        ) :: :ok
  def set_experiment_mode(model_id, mode), do: Model.set_experiment_mode(model_id, mode)

  @doc "`MontyForGraphMatching.fixme_set_ground_truth`: what this episode is about."
  @spec fixme_set_ground_truth(atom() | String.t(), map() | nil, keyword()) :: :ok
  def fixme_set_ground_truth(model_id, primary_target, opts \\ []),
    do: Model.fixme_set_ground_truth(model_id, primary_target, opts)

  @doc "`Monty.switch_to_exploratory_step`: what a recognition policy can ask for."
  @spec switch_to_exploratory_step(atom() | String.t()) :: :ok
  def switch_to_exploratory_step(model_id), do: Model.switch_to_exploratory_step(model_id)

  @doc "`Monty.time_out_lms`: what a recognition policy can ask for instead of stopping."
  @spec time_out(atom() | String.t()) :: :ok
  def time_out(model_id), do: Model.time_out(model_id)

  @doc "`MontyBase.update_ltm`: write the episode into long-term memory."
  @spec update_ltm(atom() | String.t()) :: :ok
  def update_ltm(model_id), do: Model.update_ltm(model_id)

  @doc "`MontySupervisedObjectPretrainingExperiment._pass_target_info_to_model`."
  @spec supervise(atom() | String.t(), map(), [number()], [String.t()]) :: :ok
  def supervise(model_id, target, location_on_model, supervised_ids),
    do: Model.supervise(model_id, target, location_on_model, supervised_ids)

  @doc "Stops the model's processes."
  @spec stop(atom() | String.t()) :: :ok | {:error, :not_found}
  def stop(model_id), do: Model.stop(model_id)
end
