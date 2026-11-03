defmodule ExTbpMonty.MatcherNifTest do
  @moduledoc """
  The native kernel answers what the reference calculator answers.

  `DefaultFeatureEvidenceCalculator` is the arithmetic; this is that arithmetic
  over a flat binary. The fixture is the same one the port's own parity test
  uses — Monty's `DefaultFeatureEvidenceCalculator` run over real graphs — so a
  case here is a graph the reference and Monty already agree on, and the question
  is only whether the kernel agrees with them too.

  Parity is exact, not approximate: the same columns are summed in the same
  order, so the same floats come out, and an `assert` of `==` is the honest
  statement of that. What is allowed to differ is the shape of "no evidence" —
  the kernel writes a NaN where the reference answers `nil`.
  """

  use ExUnit.Case, async: true

  alias ExTbpMonty.MatcherNif

  alias Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.Calculator.DefaultFeatureEvidenceCalculator
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory

  @fixture Path.expand("../fixtures/monty_feature_evidence.json", __DIR__)

  setup_all do
    %{"cases" => cases} = @fixture |> File.read!() |> Jason.decode!()
    {:ok, cases: cases}
  end

  test "the kernel is loaded on this machine" do
    assert MatcherNif.loaded?()
  end

  test "every recorded graph is scored exactly as the reference scores it", %{cases: cases} do
    for recorded <- cases do
      reference =
        DefaultFeatureEvidenceCalculator.calculate(
          recorded["rows"],
          recorded["feature_order"],
          recorded["feature_weights"],
          recorded["query_features"],
          recorded["tolerances"]
        )

      native = native(recorded, increment: 1)

      assert length(native) == length(reference)

      reference
      |> Enum.zip(native)
      |> Enum.each(fn
        {nil, kernel} -> assert is_nil(kernel)
        {answer, kernel} -> assert kernel == answer
      end)
    end
  end

  test "the increment scales what the reference scales", %{cases: cases} do
    for recorded <- cases, recorded["expected"] != [] do
      reference =
        DefaultFeatureEvidenceCalculator.calculate(
          recorded["rows"],
          recorded["feature_order"],
          recorded["feature_weights"],
          recorded["query_features"],
          recorded["tolerances"]
        )

      scaled = native(recorded, increment: 2.5)

      reference
      |> Enum.zip(scaled)
      |> Enum.each(fn
        {nil, kernel} -> assert is_nil(kernel)
        {answer, kernel} -> assert kernel == answer * 2.5
      end)
    end
  end

  describe "the shape of no evidence" do
    test "a row missing a compared value earns nothing" do
      # Two columns: curvature and hue. The second row has no curvature.
      rows = [[0.2, 0.1], [nil, 0.1]]

      answers =
        kernel(
          rows,
          ["curve", "hsv"],
          %{"curve" => [1], "hsv" => [1]},
          %{"curve" => [0.2], "hsv" => [0.1]},
          %{"curve" => [0.1], "hsv" => [0.1]}
        )

      assert [1.0, nil] = answers
    end

    test "a column that weighs nothing earns nothing for every row" do
      answers =
        kernel(
          [[0.2]],
          ["curve"],
          %{"curve" => [0]},
          %{"curve" => [0.2]},
          %{"curve" => [0.1]}
        )

      assert [nil] = answers
    end

    test "a graph with no rows answers nothing" do
      assert [] ==
               kernel([], ["curve"], %{"curve" => [1]}, %{"curve" => [0.2]}, %{
                 "curve" => [0.1]
               })
    end
  end

  # The same three steps the scorer takes: describe the columns, hand both to the
  # kernel, read the answers back.
  defp native(recorded, increment: increment) do
    kernel(
      recorded["rows"],
      recorded["feature_order"],
      recorded["feature_weights"],
      recorded["query_features"],
      recorded["tolerances"],
      increment
    )
  end

  defp kernel(rows, order, weights, query, tolerances, increment \\ 1) do
    columns = DefaultFeatureEvidenceCalculator.columns(order, weights, query, tolerances)
    {specs, params} = DefaultFeatureEvidenceCalculator.encode_columns(columns)
    {flat, width} = GraphMemory.flatten_rows(rows)

    flat
    |> MatcherNif.feature_evidence(width, specs, params, increment)
    |> DefaultFeatureEvidenceCalculator.decode_answers()
  end
end
