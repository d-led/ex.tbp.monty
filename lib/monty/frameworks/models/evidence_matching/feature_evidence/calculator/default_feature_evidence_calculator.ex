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

  @skip_features MapSet.new(["pose_vectors", "pose_fully_defined"])
  @circular_features MapSet.new(["hsv"])
  @categorical_features MapSet.new(["object_id"])
  @circular_range 1.0

  @impl true
  def calculate(rows, feature_order, feature_weights, query_features, tolerances) do
    columns = columns(feature_order, feature_weights, query_features, tolerances)

    Enum.map(rows, &node_evidence(&1, columns))
  end

  defp columns(feature_order, feature_weights, query_features, tolerances) do
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

  defp broadcast(values, offset) when is_list(values), do: Enum.at(values, offset)
  defp broadcast(value, _offset) when is_number(value), do: value

  defp node_evidence(row, columns) do
    node_values = Enum.map(columns, &Enum.at(row, &1.index))

    if Enum.any?(node_values, &is_nil/1) do
      nil
    else
      weighted_mean(Enum.zip_with(columns, node_values, &{&1, &2}))
    end
  end

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
