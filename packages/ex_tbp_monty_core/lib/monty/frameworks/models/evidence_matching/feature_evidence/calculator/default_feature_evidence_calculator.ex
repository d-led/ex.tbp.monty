defmodule Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.Calculator.DefaultFeatureEvidenceCalculator do
  @moduledoc """
  Feature evidence as "how far inside the tolerance is this value".

  Mirrors
  `tbp/monty/frameworks/models/evidence_matching/feature_evidence/calculator.py::DefaultFeatureEvidenceCalculator`.

  Each stored value is compared with the observation, and the difference is
  read as evidence: no difference is 1, a difference at the tolerance is 0, and
  it falls off linearly in between. The per-feature scores are then averaged
  with the feature weights, so a feature an experiment distrusts can be made
  quiet without being switched off.

  ## Three kinds of comparison

    * **numeric** — the absolute difference;
    * **circular** — the difference the short way round, so a hue of 0.99 and
      one of 0.01 are neighbours rather than 0.98 apart. Only the first value of
      a circular feature wraps (`hsv`'s hue); saturation and value do not;
    * **categorical** — equal or not, with the same linear falloff applied to
      that 0-or-1 difference.
  """

  @behaviour Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.Calculator.FeatureEvidenceCalculator

  alias ExTbpMonty.Core.MatcherNif

  @skip_features MapSet.new(["pose_vectors", "pose_fully_defined"])
  @circular_features MapSet.new(["hsv"])
  @categorical_features MapSet.new(["object_id"])
  @circular_range 1.0

  @impl true
  def calculate(rows, feature_order, feature_weights, query_features, tolerances) do
    columns = columns(feature_order, feature_weights, query_features, tolerances)

    Enum.map(rows, &node_evidence(&1, columns))
  end

  @typedoc """
  One comparison: which value of a row it reads, how, and what the answer is
  worth.

  The index counts positions in the row, so the columns of a call are numbered
  `0, 1, 2, ...` as a whole: a three-valued feature after a one-valued one starts
  at one.
  """
  @type column :: %{
          index: non_neg_integer(),
          kind: :numeric | :circular | :categorical,
          value: float(),
          tolerance: float(),
          weight: float()
        }

  @doc """
  The comparisons one observation makes against every row.

  Public because it is the whole description of the arithmetic: the rows are
  compared column by column and there is nothing else to say about it. A native
  kernel is handed these columns rather than deciding for itself what to compare.
  """
  @spec columns([String.t()], map(), map(), map()) :: [column()]
  def columns(feature_order, feature_weights, query_features, tolerances) do
    feature_order
    |> Enum.reject(&MapSet.member?(@skip_features, &1))
    |> Enum.reduce({[], 0}, fn feature, {columns, start} ->
      values = query_features |> Map.fetch!(feature) |> List.wrap()
      kinds = kinds(feature, length(values))

      segment =
        for offset <- 0..(length(values) - 1)//1 do
          %{
            index: start + offset,
            kind: Enum.at(kinds, offset),
            value: Enum.at(values, offset) * 1.0,
            tolerance: broadcast(Map.fetch!(tolerances, feature), offset) * 1.0,
            weight: broadcast(Map.fetch!(feature_weights, feature), offset) * 1.0
          }
        end

      {columns ++ segment, start + length(values)}
    end)
    |> elem(0)
  end

  @doc """
  The columns as the two binaries a native kernel reads.

  `specs` carries each column's row index and what kind of comparison applies
  (two u32); `params` carries its observed value, tolerance and weight (three
  f64). Split in two because a kind is a small integer and the rest are doubles,
  and because the kernel reads both in the same order the weights are summed in.
  """
  @spec encode_columns([column()]) :: {binary(), binary()}
  def encode_columns(columns) do
    specs =
      for column <- columns, into: <<>> do
        <<column.index::little-32, kind_code(column.kind)::little-32>>
      end

    params =
      for column <- columns, into: <<>> do
        <<column.value::float-64-little, column.tolerance::float-64-little,
          column.weight::float-64-little>>
      end

    {specs, params}
  end

  defp kind_code(:numeric), do: 0
  defp kind_code(:circular), do: 1
  defp kind_code(:categorical), do: 2

  @doc """
  A native kernel's answers, as this module's: a NaN is `nil`.

  The answers cross as bytes; `ExTbpMonty.Core.MatcherNif.decode/1` is the one place
  that turns them back into values, because a NaN there means the same thing for
  every kernel: no answer for this row.
  """
  @spec decode_answers(binary()) :: [float() | nil]
  def decode_answers(binary), do: MatcherNif.decode(binary)

  defp kinds(feature, length) do
    cond do
      MapSet.member?(@categorical_features, feature) ->
        List.duplicate(:categorical, length)

      MapSet.member?(@circular_features, feature) ->
        [:circular | List.duplicate(:numeric, length - 1)]

      true ->
        List.duplicate(:numeric, length)
    end
  end

  # numpy broadcasts a one-element list across every column of a multi-valued
  # feature, which is how a tolerance written once applies to all of them.
  defp broadcast([single], _offset), do: single
  defp broadcast(values, offset) when is_list(values), do: Enum.at(values, offset)
  defp broadcast(value, _offset) when is_number(value), do: value

  defp node_evidence(row, columns) do
    # The row is indexed once into a tuple: a list's `Enum.at` walks from the
    # front, and asking it for every column of every row of every node was most
    # of a step's time — a hundred million list steps per step of a 77-object
    # experiment.
    values = List.to_tuple(row)
    node_values = Enum.map(columns, &value_at(values, &1.index))

    if Enum.any?(node_values, &is_nil/1) do
      nil
    else
      weighted_mean(Enum.zip_with(columns, node_values, &{&1, &2}))
    end
  end

  # A row shorter than the features asked for answers nothing there, which is
  # what reading past the end of a list answered before.
  defp value_at(values, index) when index < tuple_size(values), do: elem(values, index)
  defp value_at(_values, _index), do: nil

  defp weighted_mean([]), do: nil

  defp weighted_mean(columns_and_values) do
    total_weight =
      columns_and_values
      |> Enum.map(fn {column, _value} -> column.weight end)
      |> Enum.sum()

    if total_weight == 0.0 do
      nil
    else
      columns_and_values
      |> Enum.map(fn {column, value} -> column.weight * column_evidence(column, value) end)
      |> Enum.sum()
      |> Kernel./(total_weight)
    end
  end

  defp column_evidence(%{tolerance: tolerance} = column, value) when tolerance == 0.0 do
    # A tolerance of zero is the limit of the falloff below: only an exact
    # match has evidence. Python divides by zero here and returns NaN.
    if difference(column, value) == 0.0, do: 1.0, else: 0.0
  end

  defp column_evidence(column, value) do
    max(column.tolerance - difference(column, value), 0.0) / column.tolerance
  end

  defp difference(%{kind: :numeric} = column, value), do: abs(value - column.value)

  defp difference(%{kind: :categorical} = column, value) do
    if value == column.value, do: 0.0, else: 1.0
  end

  defp difference(%{kind: :circular} = column, value) do
    raw = value - column.value

    Enum.min([
      abs(@circular_range + raw),
      abs(raw),
      abs(value - (column.value + @circular_range))
    ])
  end
end
