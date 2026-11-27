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

  # Monty's `DefaultFeatureEvidenceCalculatorTest`, whose five cases are the
  # four ways a column's evidence is made and the one feature that is skipped.
  # Hypothesis' numbers become a spread over each case's range.
  describe "Monty's own cases" do
    # test_numeric_evidence_is_linear_decay_of_absolute_distance
    test "a number's evidence falls off with the distance, to nothing at the tolerance" do
      tolerance = 2.0
      stored = [[-3.0], [0.0], [0.5], [1.0], [6.0]]

      evidence =
        calculate(stored, ["curvature"], %{"curvature" => 1.0}, %{"curvature" => tolerance})

      for {[value], mine} <- Enum.zip(stored, evidence) do
        expected = max(0.0, 1.0 - abs(value - 1.0) / tolerance)
        assert_in_delta mine, expected, @tolerance
      end
    end

    # test_circular_hue_distance_wraps_around_unit_interval
    test "a hue's distance is the short way round the circle, and the other two channels are exact" do
      tolerance = 0.25

      for {stored_hue, query_hue} <- [{0.95, 0.05}, {0.0, 0.0}, {0.5, 0.6}, {0.9, 0.4}] do
        [evidence] =
          calculate(
            [[stored_hue, 0.5, 0.5]],
            ["hsv"],
            %{"hsv" => [query_hue, 0.5, 0.5]},
            %{"hsv" => [tolerance, 1.0, 1.0]}
          )

        difference = abs(stored_hue - query_hue)
        wrapped = min(difference, 1.0 - difference)
        hue_evidence = max(0.0, 1.0 - wrapped / tolerance)
        expected = (hue_evidence + 1.0 + 1.0) / 3.0

        assert_in_delta evidence, expected, @tolerance
      end
    end

    # test_categorical_evidence_is_one_iff_equal
    test "an object id is one when it is the same id and nothing when it is not" do
      stored = [[0.0], [1.0], [2.0], [3.0], [1.0], [5.0]]

      evidence =
        calculate(stored, ["object_id"], %{"object_id" => 1.0}, %{"object_id" => 1.0})

      assert evidence == Enum.map(stored, fn [id] -> if id == 1.0, do: 1.0, else: 0.0 end)
    end

    # test_features_combine_as_weighted_average
    test "two columns combine by their weights, not by a plain average" do
      curvature = [-2.0, 0.0, 0.5]
      object_id = [0.0, 1.0, 1.0]
      rows = Enum.zip_with(curvature, object_id, &[&1, &2])

      curvature_weight = 3.0
      object_id_weight = 0.5

      evidence =
        calculate(
          rows,
          ["curvature", "object_id"],
          %{"curvature" => 0.0, "object_id" => 1.0},
          %{"curvature" => 4.0, "object_id" => 1.0},
          %{"curvature" => curvature_weight, "object_id" => object_id_weight}
        )

      for {{value, id}, mine} <- Enum.zip(Enum.zip(curvature, object_id), evidence) do
        curvature_evidence = max(0.0, 1.0 - abs(value - 0.0) / 4.0)
        object_evidence = if id == 1.0, do: 1.0, else: 0.0

        expected =
          (curvature_evidence * curvature_weight + object_evidence * object_id_weight) /
            (curvature_weight + object_id_weight)

        assert_in_delta mine, expected, @tolerance
      end
    end

    # test_skip_features_do_not_change_result
    test "the pose features are skipped, so their values change nothing" do
      stored = [[-1.0], [0.0], [0.5], [3.0]]

      baseline =
        calculate(stored, ["curvature"], %{"curvature" => 0.5}, %{"curvature" => 2.0})

      with_skip =
        calculate(
          stored,
          ["pose_vectors", "curvature", "pose_fully_defined"],
          %{"pose_vectors" => -100.0, "curvature" => 0.5, "pose_fully_defined" => 100.0},
          %{"curvature" => 2.0}
        )

      assert baseline == with_skip
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
