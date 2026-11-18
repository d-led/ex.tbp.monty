defmodule ExTbpMontyWeb.RunCompareLiveTest do
  @moduledoc """
  Two runs of one experiment, put beside each other — and the refusal when they
  are not the same experiment.
  """

  use ExTbpMontyWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Monty.Studio.RunHistory

  @experiment "tutorial/dist_agent_5lm_2obj_train"

  defp run(attrs) do
    {:ok, run} =
      RunHistory.start(
        Map.merge(
          %{experiment: @experiment, source: "monty", steps: 0, config: %{}},
          attrs
        )
      )

    run
  end

  test "two runs of one experiment, one input apart, are put side by side", %{conn: conn} do
    barrier = run(%{inputs: %{"scheduling" => "barrier"}, summary: %{"steps" => 8595}})
    lagged = run(%{inputs: %{"scheduling" => "lagged"}, summary: %{"steps" => 9000}})

    {:ok, view, _html} = live(conn, ~p"/compare?a=#{barrier.id}&b=#{lagged.id}")

    assert has_element?(view, "#compare-table")
    assert has_element?(view, "#compare-differences", "scheduling")
    assert has_element?(view, "#compare-steps", "8595")
    assert has_element?(view, "#compare-steps", "9000")
  end

  test "two different experiments are refused rather than compared", %{conn: conn} do
    one = run(%{experiment: "tutorial/first_experiment"})
    other = run(%{})

    {:ok, view, _html} = live(conn, ~p"/compare?a=#{one.id}&b=#{other.id}")

    assert has_element?(view, "#compare-refusal")
    refute has_element?(view, "#compare-table")
  end

  test "nothing is compared until two runs are picked", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/compare")

    assert has_element?(view, "#compare-form")
    refute has_element?(view, "#compare-table")
    refute has_element?(view, "#compare-refusal")
  end
end
