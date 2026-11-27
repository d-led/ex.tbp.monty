defmodule Monty.Frameworks.Models.EvidenceMatching.GraphMemoryMontyTest do
  @moduledoc """
  Translations of `tests/unit/frameworks/models/evidence_matching/graph_memory_test.py`.

  Monty's cases drive `_build_graph`, which is private; they are driven here
  through `GraphMemory.build_graph/5`, the same four arguments with memory in
  front of them, because that is the entry point a caller has.

  The mechanism differs and the event does not: Monty catches `GridTooSmallError`
  from the model's `build_model`, this port reads a tagged `{:error, reason}`
  because its core holds no exceptions. Both end with one warning and no object
  in memory. Monty's case asserts the wording of the message; this one asserts
  that the message names the object and is logged once, because the port's
  message carries the channel and the reason as well, and a test that pinned the
  sentence would be specifying a log line rather than the refusal.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Monty.Frameworks.Models.GraphMatching.GraphMemory

  # A model store that refuses everything, which is what a grid too small for the
  # locations answers. Nothing of a real model's arithmetic is under test.
  defmodule RefusingModel do
    def new(graph_id, _options), do: %{built_for: graph_id}

    def build_model(_model, _locations, _features), do: {:error, :grid_too_small}
  end

  # A model store that takes everything, and hands back the model it was given —
  # the port's shape of Monty's `build_model` returning normally.
  defmodule AcceptingModel do
    def new(graph_id, _options), do: %{built_for: graph_id}

    def build_model(model, _locations, _features), do: {:ok, model}
  end

  defp memory(object_model), do: GraphMemory.new(object_model: object_model)

  defp build(memory, graph_id, input_channel),
    do: GraphMemory.build_graph(memory, [], %{}, graph_id, input_channel)

  describe "building a graph from a list of features at locations" do
    # test_build_graph_warns_when_grid_is_too_small
    test "a grid too small for the locations is one warning, and no object in memory" do
      log =
        capture_log(fn ->
          memory = build(memory(RefusingModel), "test_object", "patch")

          assert GraphMemory.get_all_models_in_memory(memory) == %{}
        end)

      assert [_warning] =
               log |> String.split("\n", trim: true) |> Enum.filter(&(&1 =~ "test_object"))
    end

    # test_build_graph_success_does_not_warn
    test "a graph the model can hold is stored, and nothing is warned about" do
      log =
        capture_log(fn ->
          memory = build(memory(AcceptingModel), "test_object", "patch")

          assert GraphMemory.get_graph(memory, "test_object", "patch") ==
                   %{built_for: "test_object"}
        end)

      refute log =~ "warning"
    end
  end
end
