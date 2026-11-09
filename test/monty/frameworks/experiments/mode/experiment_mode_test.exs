defmodule Monty.Frameworks.Experiments.Mode.ExperimentModeTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Experiments.Mode.ExperimentMode

  # Monty makes this an enum; here it is the atom, and the strings only exist
  # where a config or a log needs them — so the two have to agree exactly.
  describe "a mode" do
    test "has the value Monty prints" do
      assert ExperimentMode.to_string(:eval) == "eval"
      assert ExperimentMode.to_string(:train) == "train"
    end

    test "comes back from that value" do
      assert ExperimentMode.from_string("eval") == {:ok, :eval}
      assert ExperimentMode.from_string("train") == {:ok, :train}
    end

    test "is refused when it is not one" do
      assert ExperimentMode.from_string("validation") == :error
      assert ExperimentMode.from_string("") == :error
    end

    test "is listed in Monty's declaration order" do
      assert ExperimentMode.all() == [:eval, :train]
    end
  end
end
