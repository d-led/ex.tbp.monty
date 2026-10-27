defmodule Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.Calculator.DefaultFeatureEvidenceCalculatorTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.Calculator.DefaultFeatureEvidenceCalculator

  @tolerance 1.0e-9

  describe "calculate/5 with one numeric feature" do
    test "a stored value equal to the observation is a perfect match" do
      assert calculate([[0.5]], ["curvature"], %{"curvature" => 0.5}, %{"curvature" => 0.2}) == [
               1.0
             ]
    end

    test "evidence falls off linearly as the difference grows towards the tolerance" do
      assert [half] =
               calculate([[0.6]], ["curvature"], %{"curvature" => 0.5}, %{"curvature" => 0.2})

      assert_in_delta half, 0.5, @tolerance
    end

    test "a difference at or beyond the tolerance is no evidence at all" do
      rows = [[0.7], [0.9]]

      for evidence <- calculate(rows, ["curvature"], %{"curvature" => 0.5}, %{"curvature" => 0.2}) do
        assert_in_delta evidence, 0.0, @tolerance
      end
    end
  end

  describe "calculate/5 with several columns" do
    test "the per-column evidence is averaged" do
      # Curvature matches exactly, rgba is far outside its tolerance.
      rows = [[0.0, 5.0]]

      assert [evidence] =
               calculate(
                 rows,
                 ["curvature", "rgba"],
                 %{"curvature" => 0.0, "rgba" => 1.0},
                 %{"curvature" => 0.1, "rgba" => 0.1}
               )

      assert_in_delta evidence, 0.5, @tolerance
    end

    test "and weighted, so a distrusted feature carries less of the average" do
      rows = [[0.0, 5.0]]

      assert [evidence] =
               calculate(
                 rows,
                 ["curvature", "rgba"],
                 %{"curvature" => 0.0, "rgba" => 1.0},
                 %{"curvature" => 0.1, "rgba" => 0.1},
                 %{"curvature" => 1, "rgba" => 2}
               )

      assert_in_delta evidence, 1 / 3, @tolerance
    end

    test "a feature weighted zero cannot pull the match down" do
      # Curvature is wildly off but weighted away; rgba is a perfect match.
      rows = [[9.0, 1.0]]

      assert [evidence] =
               calculate(
                 rows,
                 ["curvature", "rgba"],
                 %{"curvature" => 0.0, "rgba" => 1.0},
                 %{"curvature" => 0.1, "rgba" => 0.1},
                 %{"curvature" => 0, "rgba" => 1}
               )

      assert_in_delta evidence, 1.0, @tolerance
    end

    test "a multi-valued feature occupies one column per value" do
      # hsv's hue, saturation and value, in that order.
      rows = [[0.0, 0.5, 0.5]]

      assert [evidence] =
               calculate(rows, ["hsv"], %{"hsv" => [0.0, 0.5, 0.5]}, %{"hsv" => [0.1, 0.1, 0.1]})

      assert_in_delta evidence, 1.0, @tolerance
    end

    test "a zero tolerance asks for an exact match, and nothing less" do
      rows = [[0.5], [0.5000001]]

      assert calculate(rows, ["curvature"], %{"curvature" => 0.5}, %{"curvature" => 0.0}) == [
               1.0,
               0.0
             ]
    end

    test "a node with no stored values has no evidence, rather than a guess" do
      rows = [[0.5], [nil]]

      assert calculate(rows, ["curvature"], %{"curvature" => 0.5}, %{"curvature" => 0.1}) == [
               1.0,
               nil
             ]
    end
  end

  describe "calculate/5 with a circular feature" do
    test "hue is compared the short way round the colour wheel" do
      # 0.99 and 0.01 are 0.02 apart going through zero, not 0.98 apart.
      assert [near] = calculate([[0.99]], ["hsv"], %{"hsv" => [0.01]}, %{"hsv" => [0.05]})

      assert_in_delta near, 1.0 - 0.02 / 0.05, @tolerance
    end

    test "saturation and value are ordinary numbers, not angles" do
      assert [saturated] =
               calculate(
                 [[1.0, 0.9, 0.5]],
                 ["hsv"],
                 %{"hsv" => [1.0, 0.5, 0.5]},
                 %{"hsv" => [0.1, 0.1, 0.1]}
               )

      assert_in_delta saturated, (1.0 + 0.0 + 1.0) / 3, @tolerance
    end
  end

  describe "calculate/5 with a categorical feature" do
    test "the same category matches, a different one does not" do
      rows = [[1.0], [2.0]]

      assert calculate(rows, ["object_id"], %{"object_id" => 1}, %{"object_id" => 0.5}) == [
               1.0,
               0.0
             ]
    end
  end

  describe "calculate/5 and pose features" do
    test "pose vectors are not feature evidence and take no columns" do
      rows = [[0.5]]

      assert [evidence] =
               calculate(
                 rows,
                 ["pose_vectors", "curvature"],
                 %{
                   "pose_vectors" => [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
                   "curvature" => 0.5
                 },
                 %{"curvature" => 0.5},
                 %{"curvature" => 1}
               )

      assert_in_delta evidence, 1.0, @tolerance
    end
  end

  defp calculate(rows, feature_order, query_features, tolerances, weights \\ nil) do
    weights = weights || Map.new(tolerances, fn {feature, _} -> {feature, 1} end)

    DefaultFeatureEvidenceCalculator.calculate(
      rows,
      feature_order,
      weights,
      query_features,
      tolerances
    )
  end
end
