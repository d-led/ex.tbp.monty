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

  describe "reading the answers back" do
    test "the numbers the bytes hold come back in order" do
      bytes = <<1.5::float-64-little, -2.25::float-64-little, 0.0::float-64-little>>

      assert [1.5, -2.25, 0.0] == MatcherNif.decode(bytes)
    end

    test "a NaN comes back as nil, which is what it means here" do
      assert [nil] == MatcherNif.decode(MatcherNif.not_a_number())
    end

    test "a NaN whose significand sits only in the low half is still a NaN" do
      # Every exponent bit set, nothing in the high significand, one bit in the
      # low half: a NaN all the same.
      bytes = <<0x7FF0_0000_0000_0001::unsigned-64-little>>

      assert [nil] == MatcherNif.decode(bytes)
    end

    test "values around a NaN keep their place and their value" do
      bytes = <<3.0::float-64-little>> <> MatcherNif.not_a_number() <> <<-4.0::float-64-little>>

      assert [3.0, nil, -4.0] == MatcherNif.decode(bytes)
    end

    test "no bytes are no answers" do
      assert [] == MatcherNif.decode(<<>>)
    end

    test "an infinity is not a float Erlang has, so it fails rather than reading as nil" do
      # Every exponent bit set makes both an infinity and a NaN; the significand
      # is what tells them apart, and an infinity has none. There is no Erlang
      # float to answer with, and answering `nil` would call it "no answer".
      assert_raise MatchError, fn ->
        MatcherNif.decode(<<0x7FF0_0000_0000_0000::unsigned-64-little>>)
      end

      assert [nil] == MatcherNif.decode(<<0x7FF0_0000_0000_0001::unsigned-64-little>>)
    end

    test "the ends of the float range survive the round trip" do
      # Smallest subnormal, largest finite, and zero below zero.
      for bytes <- [
            <<0x0000_0000_0000_0001::unsigned-64-little>>,
            <<0x7FEF_FFFF_FFFF_FFFF::unsigned-64-little>>,
            <<0x8000_0000_0000_0000::unsigned-64-little>>
          ] do
        assert [value] = MatcherNif.decode(bytes)
        assert <<value::float-64-little>> == bytes
      end
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
