defmodule ExTbpMontyWeb.EvidenceChartTest do
  @moduledoc """
  What the chart draws that the geometry alone cannot say: the line evidence is
  measured from is on the page, and the tooltip reads the numbers the server
  already sent.
  """

  use ExTbpMontyWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ExTbpMontyWeb.EvidenceChart
  alias Monty.Studio.Chart

  defp belief(graphs) do
    %{
      possible_matches: Map.keys(graphs),
      mlh: nil,
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

  test "draws the zero line the evidence is measured from" do
    chart =
      Chart.new([
        {0, 1, belief(%{"new_object0" => 2.0})},
        {0, 2, belief(%{"new_object0" => -0.6})}
      ])

    html =
      render_component(&EvidenceChart.evidence_chart/1, %{
        module_id: "learning_module_0",
        chart: chart
      })

    assert html =~ ~s|data-zero="#{chart.zero}"|
    assert html =~ "new_object0"
  end

  # A drag and a hover each move one drawn thing: the box the drag is choosing,
  # and the line a hover stands on. Both are the picture's own, hidden until a
  # gesture uses them, so the hook only says where they stand — a node it made
  # itself is a node a patch of the chart could take away mid-gesture.
  test "brings the brush and the crosshair itself, hidden until a gesture moves them" do
    chart =
      Chart.new([
        {0, 1, belief(%{"new_object0" => 2.0})},
        {0, 2, belief(%{"new_object0" => -0.6})}
      ])

    html =
      render_component(&EvidenceChart.evidence_chart/1, %{
        module_id: "learning_module_0",
        chart: chart
      })

    document = LazyHTML.from_fragment(html)

    for marker <- ["[data-chart-brush]", "[data-chart-crosshair]"] do
      assert [drawn] = document |> LazyHTML.query(marker) |> Enum.to_list()
      assert LazyHTML.attribute(drawn, "visibility") == ["hidden"]
    end
  end
end
