defmodule ExTbpMonty.Core.MatcherNifTest do
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

  alias ExTbpMonty.Core.MatcherNif

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
      #
      # The refusal comes from different places on the two paths — a failed
      # float match in the reference, the conversion out of the NIF in the
      # native one — so the contract is that it fails, not which error it is.
      assert catch_error(MatcherNif.decode(<<0x7FF0_0000_0000_0000::unsigned-64-little>>))

      assert [nil] == MatcherNif.decode(<<0x7FF0_0000_0000_0001::unsigned-64-little>>)
    end

    test "the two readings of the bytes agree, NaN for NaN" do
      # What the NIF answers and what the Elixir reading answers are the same
      # answers: the NIF is the same reading, done where the bytes are.
      bytes =
        <<1.5::float-64-little>> <>
          MatcherNif.not_a_number() <>
          <<0x7FF0_0000_0000_0001::unsigned-64-little>> <>
          <<-0.0::float-64-little>> <>
          <<0x8000_0000_0000_0000::unsigned-64-little>> <>
          MatcherNif.not_a_number()

      assert MatcherNif.decode_reference(bytes) == MatcherNif.decode(bytes)
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

  describe "the rows a subset of a column keeps" do
    # Narrowing a hypothesis space copies rows out of the columns they are
    # already in, at three widths: one number of evidence, three of a location,
    # nine of a rotation. What has to hold is that the copy is the rows asked
    # for, in the order asked for, at the width each column has.
    test "are the rows at the indices, in the order asked for" do
      # Six numbers, so one-number rows are 1.0 … 6.0 and three-number rows are
      # [1.0, 2.0, 3.0] and [4.0, 5.0, 6.0].
      column = bytes([1.0, 2.0, 3.0, 4.0, 5.0, 6.0])

      assert MatcherNif.gather_rows(column, 1, indices([2, 0, 5])) == bytes([3.0, 1.0, 6.0])
      assert MatcherNif.gather_rows(column, 3, indices([1])) == bytes([4.0, 5.0, 6.0])

      assert MatcherNif.gather_rows(column, 3, indices([1, 0])) ==
               bytes([4.0, 5.0, 6.0, 1.0, 2.0, 3.0])
    end

    test "keep a row twice when it is asked for twice" do
      column = bytes([1.0, 2.0, 3.0])

      assert MatcherNif.gather_rows(column, 1, indices([2, 2])) == bytes([3.0, 3.0])
    end

    test "are nothing at all when nothing is asked for" do
      assert MatcherNif.gather_rows(bytes([1.0, 2.0]), 1, indices([])) == <<>>
    end
  end

  describe "the hypotheses still in the running" do
    # Monty asks `np.where(evidence > max - max / 100 * x_percent)[0]` once per
    # object per step, after checking the best clears the object threshold.
    test "are the ones inside the band under the best" do
      # best 10.0, 10 % band → threshold 9.0, strict: 9.0 itself is out.
      column = bytes([10.0, 9.0, 9.5, 1.0, 9.0001])

      assert MatcherNif.indices_within(column, 10.0, 0.0) |> ids() == [0, 2, 4]
    end

    test "are none while the best is below the object threshold" do
      column = bytes([4.0, 3.9, 1.0])

      assert MatcherNif.indices_within(column, 10.0, 5.0) |> ids() == []
    end

    # `np.max` propagates a NaN and every comparison against one is false, so a
    # column with a gap in it has no best at all — not "the best of the rest".
    test "are none when the column holds a value that is not a number" do
      column = bytes([10.0, 9.9]) <> MatcherNif.not_a_number()

      assert MatcherNif.indices_within(column, 10.0, 0.0) |> ids() == []
    end

    test "are none for an empty column" do
      assert MatcherNif.indices_within(<<>>, 10.0, 0.0) |> ids() == []
    end
  end

  describe "the runner-up hypothesis" do
    # The answer is what `argsort(evidence)[-2]` answers in Monty, which Elixir
    # spells as a sort by `{value, index}` and the element before the last — so
    # that is what the kernel is held to, ties and gaps included.
    test "is the index before the last of the column sorted by value and index" do
      for values <- [
            [1.0, 3.0, 2.0],
            [3.0, 3.0, 1.0],
            [1.0, 3.0, 3.0],
            [-2.0, -1.0, -3.0, 0.0],
            [5.0, 4.0],
            [4.0, 5.0]
          ] do
        assert MatcherNif.second_argmax_index(bytes(values)) == index_before_the_last(values),
               "for #{inspect(values)}"
      end
    end

    test "sorts a gap above every number, the way a nil sorts" do
      not_a_number = MatcherNif.not_a_number()

      for values <- [
            [1.0, nil, 2.0],
            [nil, nil],
            [nil, 1.0],
            [1.0, nil],
            [nil, nil, 2.0, 3.0]
          ] do
        bytes = encode(values, not_a_number)

        assert MatcherNif.second_argmax_index(bytes) == index_before_the_last(values),
               "for #{inspect(values)}"
      end
    end

    test "a column of fewer than two hypotheses has no runner-up" do
      assert MatcherNif.second_argmax_index(<<>>) == nil
      assert MatcherNif.second_argmax_index(bytes([1.0])) == nil
    end
  end

  defp ids(bytes), do: Monty.Frameworks.Models.EvidenceMatching.Hypotheses.index_list(bytes)

  defp indices(values), do: for(index <- values, into: <<>>, do: <<index::32-little>>)

  defp index_before_the_last(values) do
    values
    |> Enum.with_index()
    |> Enum.sort_by(fn {value, index} -> {value, index} end)
    |> Enum.at(-2)
    |> elem(1)
  end

  defp encode(values, not_a_number) do
    for value <- values, into: <<>>, do: value |> encode_one(not_a_number)
  end

  defp encode_one(nil, not_a_number), do: not_a_number
  defp encode_one(value, _not_a_number), do: <<value::float-64-little>>

  defp bytes(values), do: encode(values, MatcherNif.not_a_number())

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
