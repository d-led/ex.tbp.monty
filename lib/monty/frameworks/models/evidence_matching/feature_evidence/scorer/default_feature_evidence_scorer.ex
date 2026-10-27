defmodule Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.Scorer.DefaultFeatureEvidenceScorer do
  @moduledoc """
  Feature evidence per node for one channel of one graph.

  Mirrors
  `tbp/monty/frameworks/models/evidence_matching/feature_evidence/scorer.py::DefaultFeatureEvidenceScorer`.

  Three pieces meet here, all of them injected:

    * the **selector** decides once, at construction, whether each channel is
      matched on its features at all — a channel weighted only on poses still
      contributes pose evidence, but no feature evidence;
    * the **calculator** turns the stored feature rows into a score per node;
    * the **memory** supplies those rows and the observation's query features
      are compared against them.

  A channel that is not matched on features answers zeros rather than being
  absent: every node of that graph is still a hypothesis, it just learns nothing
  from this observation.
  """

  @behaviour Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.Scorer.FeatureEvidenceScorer

  alias Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.Calculator.DefaultFeatureEvidenceCalculator

  alias Monty.Frameworks.Models.EvidenceMatching.FeaturesForMatching.Selector.DefaultFeaturesForMatchingSelector

  alias Monty.Frameworks.Models.GraphMatching.GraphMemory

  @enforce_keys [:graph_memory, :feature_weights, :tolerances]
  defstruct graph_memory: nil,
            feature_weights: %{},
            tolerances: %{},
            calculator: DefaultFeatureEvidenceCalculator,
            increment: 1,
            use_features_by_channel: %{}

  @type t :: %__MODULE__{}

  @doc """
  A scorer over `memory`.

  `:calculator` and `:selector` name the modules doing the work, `:increment`
  scales feature evidence before it is added to a hypothesis' total — it is the
  knob an experiment turns to make feature evidence matter more than pose
  evidence.
  """
  @spec new(GraphMemory.t(), keyword()) :: t()
  def new(%GraphMemory{} = memory, options) do
    feature_weights = Keyword.fetch!(options, :feature_weights)
    tolerances = Keyword.fetch!(options, :tolerances)
    increment = Keyword.get(options, :increment, 1)
    selector = Keyword.get(options, :selector, DefaultFeaturesForMatchingSelector)

    %__MODULE__{
      graph_memory: memory,
      feature_weights: feature_weights,
      tolerances: tolerances,
      calculator: Keyword.get(options, :calculator, DefaultFeatureEvidenceCalculator),
      increment: increment,
      use_features_by_channel: selector.select(increment, feature_weights, tolerances)
    }
  end

  @impl true
  def evidence(%__MODULE__{} = scorer, graph_id, input_channel, query_features) do
    if matched_on_features?(scorer, input_channel) do
      calculate(scorer, graph_id, input_channel, query_features)
    else
      nodewise_zeros(scorer, graph_id, input_channel)
    end
  end

  @doc "Whether this channel takes part in feature matching at all."
  @spec matched_on_features?(t(), String.t()) :: boolean()
  def matched_on_features?(%__MODULE__{use_features_by_channel: by_channel}, input_channel) do
    Map.get(by_channel, input_channel, false)
  end

  defp calculate(%__MODULE__{} = scorer, graph_id, input_channel, query_features) do
    scorer.calculator.calculate(
      GraphMemory.get_feature_array(scorer.graph_memory, graph_id, input_channel),
      GraphMemory.get_feature_order(scorer.graph_memory, graph_id, input_channel),
      Map.fetch!(scorer.feature_weights, input_channel),
      query_features,
      Map.fetch!(scorer.tolerances, input_channel)
    )
    |> Enum.map(fn
      nil -> nil
      value -> value * scorer.increment
    end)
  end

  defp nodewise_zeros(%__MODULE__{} = scorer, graph_id, input_channel) do
    scorer.graph_memory
    |> GraphMemory.get_num_nodes_in_graph(graph_id, input_channel)
    |> then(fn count -> List.duplicate(0.0, count) end)
  end
end
