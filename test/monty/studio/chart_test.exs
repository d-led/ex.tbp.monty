defmodule Monty.Studio.ChartTest do
  @moduledoc """
  The chart is only as honest as its geometry.

  These tests are about the two things a chart can get wrong without anyone
  noticing: drawing a straight line through steps that were never observed, and
  making a small difference look large by cutting the axis.
  """

  use ExUnit.Case, async: true

  alias Monty.Studio.Chart

  defp belief(graphs, mlh \\ nil) do
    %{
      possible_matches: Map.keys(graphs),
      mlh: mlh,
      graphs:
        Map.new(graphs, fn {id, evidence} ->
          {id,
           %{
             hypotheses: 10,
             max_evidence: evidence,
             within_x_percent: 1,
             top_evidence: [evidence]
           }}
        end),
      x_percent_threshold: 20,
      terminal_state: nil,
      detected_object: nil
    }
  end

  describe "the vertical axis" do
    # Evidence is a sum that can fall: a hypothesis is penalised as well as
    # rewarded. The axis used to be pinned at zero whatever the data did, so
    # those points were projected below the plot area and the lines drew across
    # the x axis labels.
    test "follows the data below zero instead of drawing through the labels" do
      chart =
        Chart.new([
          {0, 1, belief(%{"mug" => 2.0})},
          {0, 2, belief(%{"mug" => -0.6})},
          {0, 3, belief(%{"mug" => -3.4})}
        ])

      assert chart.y_min <= -3.4
      assert chart.y_min == -4.0
      assert Enum.any?(chart.ticks, &(&1.value < 0)), "no tick names the part below zero"
    end

    test "still starts at zero when nothing is negative" do
      chart = Chart.new([{0, 1, belief(%{"mug" => 1.2})}, {0, 2, belief(%{"mug" => 2.4})}])

      assert chart.y_min == 0.0
    end

    # Evidence is measured from zero — every episode starts there and a
    # hypothesis is penalised below it — so the line it is measured from is
    # drawn, and it sits at the bottom of the plot exactly when the range is
    # 0..y_max.
    test "draws the line evidence is measured from" do
      below =
        Chart.new([
          {0, 1, belief(%{"mug" => 2.0})},
          {0, 2, belief(%{"mug" => -0.6})},
          {0, 3, belief(%{"mug" => -3.4})}
        ])

      above = Chart.new([{0, 1, belief(%{"mug" => 1.2})}, {0, 2, belief(%{"mug" => 2.4})}])

      # SVG's y grows downwards: on a -4..2 axis zero is a third of the way up,
      # and on a 0..3 axis it is the bottom of the plot, on the bottom margin.
      assert below.zero < above.zero
      assert above.zero == above.height - above.margin_bottom
    end

    # One label per whole unit was a working rule until a run climbed past a
    # hundred: a hundred and thirteen numbers in a plot a few hundred pixels
    # tall is a grey wall with a line lost in it. The step follows the range.
    test "labels a long run in round steps instead of every unit" do
      chart = Chart.new([{0, 1, belief(%{"mug" => 112.7})}])

      assert chart.y_max == 113.0
      assert chart.ticks |> Enum.map(& &1.label) == ~w(0 20 40 60 80 100)
    end

    test "keeps every unit while the range is small enough to read" do
      chart = Chart.new([{0, 1, belief(%{"mug" => 3.2})}])

      assert chart.ticks |> Enum.map(& &1.label) == ~w(0 1 2 3 4)
    end

    # The axis is a picture of a number line, not a list of the numbers it
    # happens to contain: an axis that grew a label per unit for every run would
    # have to be re-read for every run, and one that always jumped by ten would
    # hide the fifth of a unit a reader is watching accumulate.
    test "never draws more labels than a reader can count" do
      for evidence <- [1.0, 3.0, 7.0, 9.0, 12.0, 41.0, 112.0, 980.0] do
        chart = Chart.new([{0, 1, belief(%{"mug" => evidence})}])

        assert length(chart.ticks) <= 8, "#{length(chart.ticks)} labels for evidence #{evidence}"
      end
    end
  end

  describe "an object's line" do
    test "runs through the steps it was reported in, oldest first" do
      chart =
        Chart.new([
          {0, 1, belief(%{"mug" => 0.5})},
          {0, 2, belief(%{"mug" => 1.5})},
          {0, 3, belief(%{"mug" => 2.5})}
        ])

      assert [%{graph_id: "mug", evidence: [{0, 0.5}, {1, 1.5}, {2, 2.5}]}] = chart.series
      assert [one_segment] = chart.series |> hd() |> Map.fetch!(:points)
      assert one_segment |> String.split(" ") |> length() == 3
    end

    test "breaks where a step did not report it, instead of drawing through" do
      chart =
        Chart.new([
          {0, 1, belief(%{"mug" => 0.5})},
          {0, 2, belief(%{"mug" => 1.5})},
          {0, 3, belief(%{"bowl" => 0.5})},
          {0, 4, belief(%{"mug" => 3.5})}
        ])

      mug = Enum.find(chart.series, &(&1.graph_id == "mug"))

      assert [first, second] = mug.points
      assert first |> String.split(" ") |> length() == 2
      assert second |> String.split(" ") |> length() == 1
    end

    test "every object that was ever reported gets one" do
      chart =
        Chart.new([
          {0, 1, belief(%{"mug" => 0.5, "bowl" => 0.2})},
          {0, 2, belief(%{"mug" => 1.5, "spoon" => 0.3})}
        ])

      assert chart.series |> Enum.map(& &1.graph_id) |> Enum.sort() == ["bowl", "mug", "spoon"]
    end
  end

  describe "a run of several episodes" do
    # Every episode starts its evidence again at zero. Drawn against the step
    # alone, the second episode would be laid on top of the first — which is the
    # chart you cannot read. The x axis is the run's, so a new episode begins
    # where the one before it ended, and the drop back to zero is the boundary.
    test "begins each episode where the one before it ended, with no gap" do
      chart =
        Chart.new([
          {0, 0, belief(%{"mug" => 1.0})},
          {0, 1, belief(%{"mug" => 3.0})},
          {1, 0, belief(%{"mug" => 0.5})},
          {1, 1, belief(%{"mug" => 2.0})}
        ])

      # The second episode starts on the first one's last step: a gap would read
      # as a step that happened and was not reported.
      assert [%{evidence: [{0, 1.0}, {1, 3.0}, {1, 0.5}, {2, 2.0}]}] = chart.series
      assert {chart.x_min, chart.x_max} == {0, 2}
    end

    test "marks where each episode begins" do
      chart =
        Chart.new([
          {0, 0, belief(%{"mug" => 1.0})},
          {0, 1, belief(%{"mug" => 3.0})},
          {1, 0, belief(%{"mug" => 0.5})},
          {2, 0, belief(%{"mug" => 0.2})}
        ])

      assert Enum.map(chart.episode_starts, & &1.episode) == [0, 1, 2]
      assert Enum.map(chart.episode_starts, & &1.label) == ["ep 1", "ep 2", "ep 3"]
      assert hd(chart.episode_starts).x < hd(tl(chart.episode_starts)).x
    end

    test "does not draw a line from one episode's evidence to the next one's zero" do
      chart =
        Chart.new([
          {0, 0, belief(%{"mug" => 1.0})},
          {0, 1, belief(%{"mug" => 3.0})},
          {1, 0, belief(%{"mug" => 0.5})}
        ])

      assert [%{points: [first, second]}] = chart.series
      assert first |> String.split(" ") |> length() == 2
      assert second |> String.split(" ") |> length() == 1
    end

    test "labels an episode only when the next one leaves room for it" do
      many =
        for episode <- 0..40, do: {episode, 0, belief(%{"mug" => 1.0})}

      chart = Chart.new(many, width: 320)

      assert length(chart.episode_starts) == 41
      assert length(chart.episode_labels) < length(chart.episode_starts)
      assert hd(chart.episode_labels).label == "ep 1"
    end
  end

  describe "an episode's background" do
    # Which stretch of the run was which episode is the thing a reader counts when
    # the evidence falls back to zero. The pyview dashboard tints each episode's
    # band with the colour of the object it was about, at 0.08 — copied here, so
    # the picture a reader compares against is the same picture.
    test "covers the steps of its episode, end to end, and none of the next" do
      chart =
        Chart.new([
          {0, 0, belief(%{"mug" => 1.0})},
          {0, 1, belief(%{"mug" => 3.0})},
          {1, 0, belief(%{"mug" => 0.5})},
          {1, 1, belief(%{"mug" => 2.0})}
        ])

      assert [
               %{episode: 0, x: first_x, width: first_width},
               %{episode: 1, x: second_x}
             ] = chart.episode_bands

      # The first episode ends where the second begins: no gap, no overlap.
      assert_in_delta first_x + first_width, second_x, 0.01
      assert first_x == chart.margin_left
    end

    test "is clipped to the stretch of the run being looked at" do
      steps =
        for episode <- 0..3, step <- 0..1, do: {episode, step, belief(%{"mug" => 1.0})}

      chart = Chart.new(steps, window: {1, 3})

      assert chart.episode_bands |> Enum.map(& &1.episode) == [1, 2]
      assert hd(chart.episode_bands).x == chart.margin_left

      assert chart.episode_bands
             |> Enum.all?(fn band -> band.x + band.width <= chart.width - chart.margin_right end)
    end

    test "wears the colour of the object its episode was about" do
      chart =
        Chart.new(
          [
            {0, 0, belief(%{"mug" => 1.0})},
            {0, 1, belief(%{"mug" => 3.0})},
            {1, 0, belief(%{"bowl" => 0.5})},
            {1, 1, belief(%{"bowl" => 2.0})}
          ],
          episode_objects: %{0 => "mug", 1 => "bowl"}
        )

      assert chart.episode_bands |> Enum.map(& &1.colour) == ["#1f77b4", "#ff7f0e"]
    end

    test "an episode whose object it was not told takes a hue of its own" do
      chart =
        Chart.new([
          {0, 0, belief(%{"mug" => 1.0})},
          {0, 1, belief(%{"mug" => 3.0})},
          {1, 0, belief(%{"mug" => 0.5})},
          {1, 1, belief(%{"mug" => 2.0})}
        ])

      assert [first, second] = Enum.map(chart.episode_bands, & &1.colour)
      assert first =~ "hsl("
      assert first != second
    end
  end

  describe "the colour and place an object is given" do
    # The pyview dashboard's `getObjectColor`, copied: named objects wear tab10,
    # which is why a line keeps its colour while the lines reorder themselves.
    test "is the palette's, by name, wherever the object ranks" do
      assert Chart.colour("mug") == "#1f77b4"
      assert Chart.colour("banana") == "#17becf"
      assert Chart.colour("mug", 7) == "#1f77b4"
    end

    test "is a golden-angle hue when the name is not one Monty knows" do
      assert Chart.colour("new_object0", 0) =~ "hsl("
      assert Chart.colour("new_object0", 0) != Chart.colour("new_object1", 1)
    end

    test "never gives two objects of a run the same colour" do
      names = ["mug", "bowl", "potted_meat_can", "spoon", "strawberry", "mustard_bottle"]

      assert names |> Enum.map(&Chart.colour/1) |> Enum.uniq() |> length() == length(names)
    end

    # A chart is rebuilt on every step and its lines are drawn worst-first, so the
    # drawing order moves whenever an object overtakes another. What a reader
    # carries from one step to the next is that the blue line is the same object —
    # so the colour and the legend place are assigned once, kept in a map, and
    # handed back in with the next chart. They used to be derived from the
    # drawing position, which repainted every object each time the ranking moved.
    test "belongs to the object once it has appeared, not to where it is drawn" do
      steps = [
        {0, 1, belief(%{"new_object0" => 1.0, "new_object1" => 2.0})},
        {0, 2, belief(%{"new_object0" => 3.0, "new_object1" => 2.5})}
      ]

      chart = Chart.new(steps)

      # A step later: another object appears and the two of them change places.
      later =
        Chart.new(
          steps ++
            [{0, 3, belief(%{"new_object0" => 2.0, "new_object1" => 4.0, "new_object2" => 1.0})}],
          labels: chart.labels
        )

      assert series_ids(later) != series_ids(chart),
             "the ranking did not move, so this proves nothing"

      assert colour_of(later, "new_object0") == colour_of(chart, "new_object0")
      assert colour_of(later, "new_object1") == colour_of(chart, "new_object1")

      # The newcomer takes the next free place; nobody else shifts.
      assert legend_ids(later) == legend_ids(chart) ++ ["new_object2"]
    end

    test "keeps the legend's order while the lines re-rank" do
      object_first =
        Chart.new([
          {0, 1, belief(%{"new_object0" => 1.0, "new_object1" => 2.0})},
          {0, 2, belief(%{"new_object0" => 3.0, "new_object1" => 2.5})}
        ])

      other_first =
        Chart.new([
          {0, 1, belief(%{"new_object0" => 1.0, "new_object1" => 2.0})},
          {0, 2, belief(%{"new_object0" => 2.5, "new_object1" => 3.0})}
        ])

      assert series_ids(object_first) != series_ids(other_first)

      assert legend_ids(object_first) == legend_ids(other_first)
    end
  end

  defp series_ids(chart), do: Enum.map(chart.series, & &1.graph_id)

  defp legend_ids(chart), do: Enum.map(chart.legend, & &1.graph_id)

  defp colour_of(chart, graph_id) do
    chart.series |> Enum.find(&(&1.graph_id == graph_id)) |> Map.fetch!(:colour)
  end

  describe "the axes" do
    test "start at zero, because evidence is a sum from zero" do
      chart = Chart.new([{0, 1, belief(%{"mug" => 20.0})}])

      assert chart.y_min == 0.0
      assert chart.y_max == 20.0
    end

    test "cover every step that was reported" do
      chart =
        Chart.new([
          {0, 4, belief(%{"mug" => 1.0})},
          {0, 9, belief(%{"mug" => 2.0})}
        ])

      # The run's x begins at the first step of the first episode.
      assert {chart.x_min, chart.x_max} == {0, 5}
    end

    test "a chart with no steps still has a scale to divide by" do
      chart = Chart.new([])

      assert chart.series == []
      assert chart.y_max > 0
      assert chart.mlh == nil
    end
  end

  describe "the most likely hypothesis" do
    test "is marked on the line of the object it names, at the last step" do
      mlh = %{
        graph_id: "mug",
        id: 0,
        location: [0.0, 0.0, 0.0],
        rotation_wxyz: [1.0, 0.0, 0.0, 0.0],
        evidence: 2.0
      }

      chart =
        Chart.new([
          {0, 1, belief(%{"mug" => 0.5}, mlh)},
          {0, 2, belief(%{"mug" => 2.0}, mlh)}
        ])

      assert chart.mlh.graph_id == "mug"
      # The marker sits at the last step's x, which is the right-hand edge of the plot.
      assert chart.mlh.x == chart.width - 12
      assert chart.mlh.y < chart.height
    end
  end

  describe "a stretch of the run" do
    test "is all a chart draws when it is given a window, and it says how long the run is" do
      steps = [
        {0, 0, belief(%{"mug" => 0.1})},
        {0, 1, belief(%{"mug" => 0.2})},
        {0, 2, belief(%{"mug" => 0.3})},
        {0, 3, belief(%{"mug" => 0.4})}
      ]

      chart = Chart.new(steps, window: {1, 3})

      assert {chart.x_min, chart.x_max} == {1, 3}
      assert Chart.extent(steps) == {0, 3}
      # Both ends are in: "steps 1–3" is three steps of a four-step run, and the
      # step before the window is not one of them.
      assert chart.series |> hd() |> Map.fetch!(:evidence) == [{1, 0.2}, {2, 0.3}, {3, 0.4}]
    end

    test "cannot reach past either end of the run" do
      steps = [{0, 0, belief(%{"mug" => 0.1})}, {0, 1, belief(%{"mug" => 0.2})}]

      chart = Chart.new(steps, window: {-5, 99})

      assert {chart.x_min, chart.x_max} == {0, 1}
    end

    test "is the whole run when the window is empty or back to front" do
      steps = [{0, 0, belief(%{"mug" => 0.1})}, {0, 1, belief(%{"mug" => 0.2})}]

      for window <- [{1, 1}, {1, 0}, :nonsense] do
        chart = Chart.new(steps, window: window)

        assert {chart.x_min, chart.x_max} == {0, 1}
        assert chart.series != []
      end
    end
  end
end
