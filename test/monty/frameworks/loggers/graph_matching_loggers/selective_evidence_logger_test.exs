defmodule Monty.Frameworks.Loggers.GraphMatchingLoggers.SelectiveEvidenceLoggerTest do
  @moduledoc """
  The evidence pool: what each hypothesis carried at the end of an episode, and the
  frame a sensor saw first.

  The pool is staked out as a value here (`pool/3`, from the module views a model
  answers), because that map is what an object-similarity analysis reads.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Loggers.GraphMatchingLoggers.SelectiveEvidenceLogger, as: Logger
  alias Monty.Frameworks.Models.Buffer.FeatureAtLocationBuffer
  alias Monty.Frameworks.Models.EvidenceMatching.GraphMemory.EvidenceGraphMemory
  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM

  defmodule KeepsFrames do
    @moduledoc false
    def state_dict(_state), do: %{"raw_observations" => ["first frame", "second frame"]}
  end

  defmodule KeepsNoFrames do
    @moduledoc false
    def state_dict(_state), do: %{}
  end

  # A buffer after two steps with a detailed logger: every statistic is a list of
  # per-step values, which is what the two index choices below are about.
  defp stepped_buffer do
    %{
      FeatureAtLocationBuffer.new()
      | stats: %{
          "evidences" => [%{"mug_graph" => 0.4}, %{"mug_graph" => 0.9}],
          "possible_locations" => [
            %{"mug_graph" => [[0.0, 0.0, 0.0]]},
            %{"mug_graph" => [[0.1, 0.0, 0.0]]}
          ],
          "possible_rotations" => [%{"mug_graph" => [[0.0, 0.0, 0.0]]}],
          "possible_matches" => [["mug_graph", "bowl_graph"], ["mug_graph"]],
          "current_mlh" => [%{"graph_id" => "mug_graph"}, %{"graph_id" => "mug_graph"}],
          "symmetry_evidence" => [0, 1]
        }
    }
  end

  defp learning_module(buffer) do
    {:ok, lm} = EvidenceGraphLM.new(EvidenceGraphMemory.new(), max_match_distance: 0.05)
    %{lm | buffer: buffer}
  end

  defp modules(overrides) do
    Map.merge(
      %{
        learning_modules: [
          %{id: :lm_0, module: EvidenceGraphLM, state: learning_module(stepped_buffer())}
        ],
        sensor_modules: []
      },
      Map.new(overrides)
    )
  end

  defp pool(overrides), do: Logger.pool(modules(overrides), %{}, :eval)

  test "keeps the last step's evidence and where the object could be, and every step's belief" do
    # Monty's two index choices: `[-1]` for the state the episode ended in, the
    # whole statistic for how it got there.
    entry = pool([])["LM_0"]

    assert entry["evidences_ls"] == %{"mug_graph" => 0.9}
    assert entry["possible_locations_ls"] == %{"mug_graph" => [[0.1, 0.0, 0.0]]}
    assert entry["possible_matches"] == [["mug_graph", "bowl_graph"], ["mug_graph"]]
    assert entry["current_mlh"] == [%{"graph_id" => "mug_graph"}, %{"graph_id" => "mug_graph"}]
    assert entry["symmetry_evidence"] == [0, 1]
  end

  test "keeps the possible rotations once, because an episode's poses do not change" do
    assert pool([])["LM_0"]["possible_rotations_ls"] == [%{"mug_graph" => [[0.0, 0.0, 0.0]]}]
  end

  test "says nothing rather than failing for an episode that never stepped" do
    # Python's `[-1]` on an empty list is an IndexError; a module with no step has
    # no last step, and `nil` is that answer without the crash.
    empty = %{
      id: :lm_0,
      module: EvidenceGraphLM,
      state: learning_module(%FeatureAtLocationBuffer{})
    }

    entry = Logger.pool(modules(learning_modules: [empty]), %{}, :eval)["LM_0"]

    assert entry["evidences_ls"] == nil
    assert entry["possible_locations_ls"] == nil
  end

  test "keeps the first frame a sensor saw, and nothing from a sensor that kept none" do
    kept = %{id: :view_finder, module: KeepsFrames, state: %{}}
    quiet = %{id: :patch, module: KeepsNoFrames, state: %{}}

    assert pool(sensor_modules: [kept])["SM_0"] == "first frame"
    refute Map.has_key?(pool(sensor_modules: [quiet]), "SM_0")
  end
end
