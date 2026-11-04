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

  What the model does rather than owns is here: `combine_votes/2`, the one piece
  of `_combine_votes` that is arithmetic rather than message passing.
  `Monty.Runtime.Step.State` routes votes and calls it.

  A config that names a model this port has not written is not run through this
  one: `Monty.Studio.Setup.model_class/1` answers what a config resolves to, and
  says plainly when the answer is this port's own runtime instead.
  """

  alias Monty.Cmp.Message
  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Geometry
  alias Monty.Geometry.OrientationMatrix
  alias Monty.Runtime.Model

  @typedoc """
  What a learning module says when it is asked to vote.

  `possible_states` holds the hypotheses that stood out above the module's vote
  threshold, one list per object; `sensed_pose_rel_body` is the pose of the
  sensor that fed it — the location, then its three pose vectors. `nil` is a
  module with nothing to say this step.
  """
  @type vote ::
          nil
          | %{
              possible_states: %{optional(term()) => [Message.t()]},
              sensed_pose_rel_body: [[float()]]
            }

  @doc """
  `EvidenceGraphModel._combine_votes`: what a module hears, in the frame of its
  own sensor.

  Two learning modules look at the object through different sensors, so a vote
  for a place on it only means something once it has been moved between them:
  *"if I am here, you should be there."* The displacement between the sending
  and the receiving sensor moves the vote's location, and the rotation that
  takes the sending sensor's pose vectors to the receiving one's turns the
  vote's own pose — vote rotations are not read yet, in Monty either.

  The answer is keyed by receiver, then by object, which is the shape
  `EvidenceGraphLM.receive_votes/2` reads. A module that did not vote this step
  hears nothing, and neither does one whose sources were all silent: a module
  with no opinion of its own is not a place to put other modules' opinions.
  """
  @spec combine_votes(%{optional(term()) => vote()}, %{optional(term()) => [term()]}) ::
          %{optional(term()) => %{optional(term()) => [Message.t()]}}
  def combine_votes(votes, lm_to_lm_vote) do
    Map.new(lm_to_lm_vote, fn {receiver, sources} ->
      {receiver, heard(votes, receiver, sources)}
    end)
  end

  defp heard(votes, receiver, sources) do
    case Map.get(votes, receiver) do
      nil ->
        %{}

      %{sensed_pose_rel_body: receiving_pose} ->
        sources
        |> Enum.map(&Map.get(votes, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.reduce(%{}, &merge_vote(&1, receiving_pose, &2))
    end
  end

  # One source's vote, object by object: its messages moved into the receiving
  # sensor's frame and added to what this receiver has already heard about that
  # object, so two sources agree on the same object rather than replacing each
  # other.
  defp merge_vote(vote, receiving_pose, heard) do
    vote.possible_states
    |> Enum.map(fn {graph_id, messages} ->
      {graph_id, Enum.map(messages, &move(&1, vote.sensed_pose_rel_body, receiving_pose))}
    end)
    |> Enum.reduce(heard, fn {graph_id, moved}, acc ->
      Map.update(acc, graph_id, moved, &(&1 ++ moved))
    end)
  end

  # Monty copies a vote before moving it, because one vote can reach several
  # receivers and be moved differently in each; a value that cannot change
  # gives that for free.
  defp move(%Message{} = message, sending_pose, receiving_pose) do
    [sending_location | sending_frame] = sending_pose
    [receiving_location | receiving_frame] = receiving_pose

    {:ok, moved} =
      Message.transform_morphological_features(
        message,
        Geometry.apply(
          vote_frame(message),
          Geometry.subtract(receiving_location, sending_location)
        ),
        SpatialArithmetics.align_orthonormal_vectors_as_matrix(sending_frame, receiving_frame)
      )

    moved
  end

  # The frame stays a matrix rather than a `Rotation`: a stored frame is only
  # approximately orthonormal, and rounding the product to the nearest rotation
  # moves the displacement it turns by millimetres (`SpatialArithmetics` says
  # why that matters). A vote carrying anything but an `OrientationMatrix`
  # cannot be turned at all, which is Monty's `TypeError` here.
  defp vote_frame(%Message{} = message) do
    {:ok, %OrientationMatrix{value: value}} = Message.feature(message, "pose_vectors")
    value
  end

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

  Monty's own signature takes the world's `semantic_id_to_label` beside the
  target, and both come from the same place: the world that chose the object also
  numbered it. It is an option here rather than a second positional argument,
  because a world without semantics has none to give.
  """
  @spec fixme_set_ground_truth(atom() | String.t(), map() | nil, keyword()) :: :ok
  def fixme_set_ground_truth(model_id, primary_target, opts \\ []),
    do: Model.fixme_set_ground_truth(model_id, primary_target, opts)

  @doc "The four things a recognition policy may read off the model."
  @spec status(atom() | String.t()) :: Monty.Experiment.RecognitionPolicy.model()
  def status(model_id), do: Model.status(model_id)

  @doc """
  `MontyBase.set_experiment_mode`: whether this episode trains or evaluates.

  The experiment knows — it runs training epochs or evaluation epochs — but what
  an episode is working *towards* is the model's own business: an evaluation that
  recognises its object ends, a training episode switches to exploring, and a
  model that was told nothing does neither. Monty calls this on the model before
  an epoch steps, so this port does too.
  """
  @spec set_experiment_mode(
          atom() | String.t(),
          Monty.Frameworks.Models.AbstractMontyClasses.LearningModule.mode()
        ) :: :ok
  def set_experiment_mode(model_id, mode), do: Model.set_experiment_mode(model_id, mode)

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
