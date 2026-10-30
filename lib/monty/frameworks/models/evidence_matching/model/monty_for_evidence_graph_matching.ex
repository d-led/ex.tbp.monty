defmodule Monty.Frameworks.Models.EvidenceMatching.Model.MontyForEvidenceGraphMatching do
  @moduledoc """
  Monty's model for evidence-graph matching:
  `tbp/monty/frameworks/models/evidence_matching/model.py`.

  In Monty this class is the base model with a graph memory whose learning
  modules carry hypotheses and accumulate evidence for them; its `__init__`
  builds the model out of the config's sensor modules, learning modules and the
  connectivity between them, and the base class steps it.

  Here the two halves are separated, which is the split this port makes
  everywhere: *what* the model is — the sensor modules, the learning modules,
  the matrices — is read from the config by `Monty.Studio.Setup.model_spec/2`,
  and *running* it is the runtime's business (`Monty.Runtime.Model` registers the
  modules, the step coordinator and the episode's random stream as processes).
  This module is the name a run uses for that model, which is what makes the
  class in a config the class a run actually starts.

  A config that names a model this port has not written is not run through this
  one: `Monty.Studio.Setup.model_class/1` answers what a config resolves to, and
  says plainly when the answer is this port's own runtime instead.
  """

  alias Monty.Runtime.Model

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
  One timestep: what the modules were given and what they made of it.

  Monty's `Monty.step`, without the model having to be a value: the modules are
  processes and the coordinator keeps the step count.
  """
  @spec step(atom() | String.t(), map(), map(), Monty.Context.t()) ::
          {:ok, [map()], map()}
  def step(model_id, observations, proprioceptive_state, ctx),
    do: Model.step(model_id, observations, proprioceptive_state, ctx)

  @doc "The coordinator's state, which is where an episode's conclusion lives."
  @spec state(atom() | String.t()) :: Monty.Runtime.Step.State.t()
  def state(model_id), do: Model.state(model_id)

  @doc """
  `MontyForGraphMatching.fixme_set_ground_truth`: what this episode is about.

  The experiment is the only one that knows, and a module that is never told cannot
  say whether it recognised anything — so this is part of the model's public
  surface, not the experiment's private business.
  """
  @spec fixme_set_ground_truth(atom() | String.t(), map() | nil) :: :ok
  def fixme_set_ground_truth(model_id, primary_target),
    do: Model.fixme_set_ground_truth(model_id, primary_target)

  @doc "The four things a recognition policy may read off the model."
  @spec status(atom() | String.t()) :: Monty.Experiment.RecognitionPolicy.model()
  def status(model_id), do: Model.status(model_id)

  @doc "`Monty.switch_to_exploratory_step`: what a recognition policy can ask for."
  @spec switch_to_exploratory_step(atom() | String.t()) :: :ok
  def switch_to_exploratory_step(model_id), do: Model.switch_to_exploratory_step(model_id)

  @doc "`Monty.time_out_lms`: what a recognition policy can ask for instead of stopping."
  @spec time_out(atom() | String.t()) :: :ok
  def time_out(model_id), do: Model.time_out(model_id)

  @doc "Stops the model's processes."
  @spec stop(atom() | String.t()) :: :ok | {:error, :not_found}
  def stop(model_id), do: Model.stop(model_id)
end
