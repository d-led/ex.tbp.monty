defmodule ExTbpMontyWeb.RunsLiveTest do
  use ExTbpMontyWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "the synthetic run" do
    test "offers a start button and no steps before it is used", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/runs/demo")

      assert has_element?(view, "#start")
      refute has_element?(view, "#steps-step-0")
    end

    test "one click advances exactly one timestep and streams what happened", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/runs/demo")

      view |> element("#start") |> render_click()
      # The step is broadcast on PubSub; wait until the LiveView has handled it
      # instead of sleeping.
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#steps-step-0")
      assert view |> element("#steps-step-0") |> render() =~ "percepts"
      assert view |> element("#steps-step-0") |> render() =~ "votes"
    end

    test "stepping again adds the next step instead of replacing the log", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/runs/demo")

      view |> element("#start") |> render_click()
      _ = :sys.get_state(view.pid)
      view |> element("#step") |> render_click()
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#steps-step-0")
      assert has_element?(view, "#steps-step-1")
    end

    test "the step button does nothing until a run exists", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/runs/demo")

      assert view |> element("#step") |> render() =~ "disabled"
      refute has_element?(view, "#steps-step-0")
    end
  end
end
