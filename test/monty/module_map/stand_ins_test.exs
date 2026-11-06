defmodule Monty.ModuleMap.StandInsTest do
  use ExUnit.Case, async: true

  alias Monty.ModuleMap.StandIns

  describe "what runs in place of a class" do
    test "the shells are replaced by the runtime, and say which part does what" do
      stand_ins =
        StandIns.for_class("MontyForGraphMatching", "frameworks/models/graph_matching.py")

      assert Enum.map(stand_ins, & &1.name) == [Monty.Runtime.Model, Monty.Runtime.Step]

      # `Monty` is the same shell, named from the other end: the class that owns
      # the modules a config names.
      assert StandIns.for_class("Monty", "frameworks/models/abstract_monty_classes/monty.py") ==
               stand_ins
    end

    test "a MuJoCo class is carried as Python, not replaced by an Elixir module" do
      assert [%{kind: :file, path: "priv/monty_py/world.py"}] =
               StandIns.for_class("MuJoCoSimulator", "simulators/mujoco/simulator.py")
    end

    test "a learning module nothing stands in for has no stand-in at all" do
      # The difference the column exists to show: a config naming one of these
      # is refused, rather than quietly run on something else.
      assert StandIns.for_class("GraphLM", "frameworks/models/graph_matching.py") == []
    end
  end
end
