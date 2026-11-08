defmodule Monty.Attention.WeightPoolerTest do
  @moduledoc """
  Translations of `tests/unit/attention/weight_pooler_test.py` (two cases, both
  properties, one for one).
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Monty.Attention.WeightPooler

  describe "negative_priority_max_pool/1 (NegativePriorityMaxPoolTest)" do
    # test_call_returns_max_value_if_all_are_non_negative
    property "returns the maximum when no value is negative" do
      check all(values <- list_of(float(min: 0.0), min_length: 1)) do
        assert WeightPooler.negative_priority_max_pool(values) == Enum.max(values)
      end
    end

    # test_call_returns_most_negative_value_if_any_are_negative
    property "returns the most negative value when any value is negative" do
      check all(
              leading <- list_of(float(min: 0.0, max: 1.0)),
              negative <- float(min: -1.0, max: -0.01),
              trailing <- list_of(float(min: -1.0, max: 1.0))
            ) do
        values = leading ++ [negative | trailing]

        assert WeightPooler.negative_priority_max_pool(values) == Enum.min(values)
      end
    end
  end
end
