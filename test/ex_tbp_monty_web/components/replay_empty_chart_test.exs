defmodule ExTbpMontyWeb.Components.ReplayEmptyChartTest do
  @moduledoc """
  A chart with nothing on it is not drawn.

  A training run has no evidence to plot, and the page says so in a sentence. The
  box of axes that used to sit under that sentence read as a chart that had
  failed rather than as a run that had nothing to show, so the panel is rendered
  only when there is a line to draw.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Monty.Studio.Replay.Chart

  @samples "hover"

  defp chart(lines) do
    %Chart{lines: lines, min: 0.0, max: 1.0, from: 0, to: 10, paths: [], hover: [], ticks: []}
  end

  defp line(points), do: %{id: "evidence", label: "evidence", points: points, colour: "#3355aa"}

  test "a run with no line to draw keeps the sentence and loses the box" do
    html =
      render_component(&ExTbpMontyWeb.StudioComponents.replay/1, %{
        samples: @samples,
        chart: chart([]),
        recorded: 0
      })

    refute html =~ "replay-chart-panel"
  end

  test "a chart whose lines are all outside the window is not drawn either" do
    html =
      render_component(&ExTbpMontyWeb.StudioComponents.replay/1, %{
        samples: @samples,
        chart: chart([line([])]),
        recorded: 0
      })

    refute html =~ "replay-chart-panel"
  end

  test "a chart with a point in it is drawn" do
    html =
      render_component(&ExTbpMontyWeb.StudioComponents.replay/1, %{
        samples: @samples,
        chart: chart([line([%{x: 1, y: 0.5, object: nil}])]),
        recorded: 1
      })

    assert html =~ "replay-chart-panel"
  end
end
