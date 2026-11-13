defmodule Monty.Studio.Chart.StackingTest do
  use ExUnit.Case, async: true

  alias Monty.Studio.Chart

  # Every episode reports its steps from zero again, so the chart has to lay them
  # end to end on one axis. Getting this wrong is not cosmetic: overlapping
  # episodes draw one episode's evidence on top of another's, and a run whose
  # evidence resets appears to climb without ever coming down.
  describe "episodes that each count from zero" do
    test "are laid end to end, one step apart so no two share a column" do
      steps = [
        {0, 0, :belief},
        {0, 1, :belief},
        {0, 2, :belief},
        {1, 0, :belief},
        {1, 1, :belief},
        {1, 2, :belief}
      ]

      # Two episodes of three steps reach step five: the second begins one step
      # after the first ends, because two episodes sharing a column were two
      # climbs drawn at one x — the line of one running on into the other's band.
      assert Chart.extent(steps) == {0, 5}
    end

    test "and a run of one episode is just its own steps" do
      assert Chart.extent([{0, 0, :belief}, {0, 4, :belief}]) == {0, 4}
    end
  end
end
