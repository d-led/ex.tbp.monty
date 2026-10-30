defmodule Monty.Studio.Belief do
  @moduledoc """
  What a learning module holds after a step, in the names Monty uses.

  A run's page, its log and its database row all want the same handful of
  numbers, and all three want them to be *the module's*: which objects are still
  possible, which hypothesis it currently believes, where that hypothesis puts the
  object and how sure it is, and — per object — how many explanations are still
  alive, how strong the best one is and how many of them are close enough to it to
  be worth testing. Nothing here is derived, smoothed or simulated: every field is
  read off `EvidenceGraphLM`, and the four per-object numbers are the ones the
  recorder writes for Monty, so a live chart and a recorded episode are the same
  measurement of the same thing.

  A module that keeps no hypothesis space — the synthetic stand-in a config whose
  learning module is not ported gets — has no belief to report, and says so, which
  is why `of/1` answers `nil` for the most likely hypothesis rather than inventing
  one.
  """

  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
  alias Monty.Runtime.{LearningModuleServer, Registry}

  # How many of an object's best hypotheses a chart draws. The best one is the
  # answer; the next few are how crowded the answer is.
  @top 5

  @typedoc """
  One object's hypothesis space after a step.

  `hypotheses` is how many explanations of the object the module is carrying,
  `max_evidence` the strongest of them, and `within_x_percent` how many are close
  enough to the strongest (`x_percent_threshold` of it) to be tested for pose —
  the set an episode's conclusion is drawn from.
  """
  @type graph :: %{
          hypotheses: non_neg_integer(),
          max_evidence: float(),
          within_x_percent: non_neg_integer(),
          top_evidence: [float()]
        }

  @typedoc """
  The hypothesis the module believes most, as it stands after this step.

  `rotation_wxyz` is in Monty's order — scalar first — because that is the order
  Monty's `Rotation.as_quat/0` and every recording use; the port's own
  `Rotation.to_xyzw/1` is the one that reorders.
  """
  @type mlh :: %{
          graph_id: String.t(),
          id: non_neg_integer(),
          location: [float()],
          rotation_wxyz: [float()],
          evidence: number()
        }

  @type t :: %{
          possible_matches: [String.t()],
          mlh: mlh() | nil,
          graphs: %{optional(String.t()) => graph()},
          x_percent_threshold: number(),
          terminal_state: atom() | nil,
          detected_object: String.t() | nil
        }

  @doc "The belief of one learning module, or `nil` if it keeps no hypothesis space."
  @spec of(term()) :: t() | nil
  def of(%EvidenceGraphLM{} = module) do
    %{
      possible_matches: module.possible_matches,
      mlh: mlh(EvidenceGraphLM.current_mlh(module)),
      graphs: graphs(module),
      x_percent_threshold: module.x_percent_threshold,
      terminal_state: module.terminal_state,
      detected_object: module.detected_object
    }
  end

  def of(_module_without_a_hypothesis_space), do: nil

  @doc "The belief of a running module, by the model and module ids it was started with."
  @spec of(String.t(), atom() | String.t()) :: t() | nil
  def of(model_id, module_id) do
    {:learning_module, model_id, module_id}
    |> Registry.via()
    |> LearningModuleServer.state()
    |> of()
  end

  @doc "Every learning module of a model that holds a belief, keyed by module id."
  @spec all(String.t(), [atom() | String.t()]) :: %{optional(atom() | String.t()) => t()}
  def all(model_id, module_ids) do
    module_ids
    |> Enum.flat_map(fn module_id ->
      case of(model_id, module_id) do
        nil -> []
        belief -> [{module_id, belief}]
      end
    end)
    |> Map.new()
  end

  # A module that has seen nothing is Monty's "there are no observations": its
  # current hypothesis has no id, and a hypothesis with no id is no hypothesis.
  defp mlh(%{mlh_id: nil}), do: nil

  defp mlh(mlh) do
    %{
      graph_id: mlh.graph_id,
      id: mlh.mlh_id,
      location: mlh.location,
      rotation_wxyz: Tuple.to_list(mlh.rotation.wxyz),
      evidence: mlh.evidence
    }
  end

  defp graphs(module) do
    module.hypotheses
    |> Enum.reject(fn {_graph_id, space} -> space.evidence == [] end)
    |> Map.new(fn {graph_id, space} -> {graph_id, graph(space.evidence, module)} end)
  end

  # The four numbers a conclusion turns on, computed once for both the chart and
  # the recorder: how many, how strong, how many close behind, and the leaders.
  defp graph(scores, module) do
    best = Enum.max(scores)
    band = best - best / 100 * module.x_percent_threshold

    %{
      hypotheses: length(scores),
      max_evidence: best,
      within_x_percent: if(best > 0, do: Enum.count(scores, &(&1 > band)), else: 0),
      top_evidence: scores |> Enum.sort(:desc) |> Enum.take(@top)
    }
  end
end
