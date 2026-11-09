defmodule Monty.Studio.Chart.StackingTest do
  use ExUnit.Case, async: true

  alias Monty.Studio.Chart

  # Every episode reports its steps from zero again, so the chart has to lay them
  # end to end on one axis. Getting this wrong is not cosmetic: overlapping
  # episodes draw one episode's evidence on top of another's, and a run whose
  # evidence resets appears to climb without ever coming down.
  describe "episodes that each count from zero" do
    test "are laid end to end, sharing the step where one hands over to the next" do
      steps = [
        {0, 0, :belief},
        {0, 1, :belief},
        {0, 2, :belief},
        {1, 0, :belief},
        {1, 1, :belief},
        {1, 2, :belief}
      ]

      # Two episodes of three steps reach step four, not step five: the second
      # episode begins on the step the first one ended on, because a gap between
      # them would be a step the chart claims nobody reported.
      assert Chart.extent(steps) == {0, 4}
    end

    test "and a run of one episode is just its own steps" do
      assert Chart.extent([{0, 0, :belief}, {0, 4, :belief}]) == {0, 4}
    end
  end
end
