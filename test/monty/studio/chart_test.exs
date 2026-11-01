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
end
