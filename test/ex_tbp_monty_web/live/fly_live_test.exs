defmodule ExTbpMontyWeb.FlyLiveTest do
  @moduledoc """
  The fly page: a press walks the body, and the page says where it got to.

  A body needs an interpreter this application does not carry (FlyGym's MuJoCo and
  this one cannot share a process), so the cases that step a body skip with the
  reason when a machine names none — the same sentence the page itself gives. The
  page's other state, the one a machine without a body sees, is proved by asking
  for it: the variable is unset for that one render, and restored after it.
  """

  use ExTbpMontyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Monty.Simulators.Flygym.World
  alias Monty.Test.Tmp

  @skip_reason if World.available?(), do: nil, else: World.unavailable_reason()

  describe "a node with no fly body" do
    test "says what to set instead of offering presses that cannot work", %{conn: conn} do
      # A machine that has the body is put in the same place as one that has not:
      # no interpreter in either place a body is looked for.
      Tmp.without_env("FLYGYM_PYTHON")
      Tmp.system_env("MONTY_DATA", Tmp.dir("fly-live-no-body"))

      {:ok, _view, html} = live(conn, ~p"/fly")

      assert html =~ "no interpreter with the fly body"
      assert html =~ "FLYGYM_PYTHON"
      assert html =~ "pip install flygym"
      refute html =~ "fly-forward"
    end
  end

  describe "a node with a fly body" do
    @describetag skip: @skip_reason

    test "offers the three presses a body has", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/fly")

      assert has_element?(view, "#fly-forward")
      assert has_element?(view, "#fly-left")
      assert has_element?(view, "#fly-right")
      assert has_element?(view, "#fly-path")
      assert has_element?(view, "#fly-eyes")
    end

    test "walks the body when a press arrives, and shows what the eyes read", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/fly")

      html = view |> element("#fly-forward") |> render_click()

      assert html =~ "presses"
      assert has_element?(view, "#fly-eye-bars")
      assert has_element?(view, "#fly-eye-0")
    end

    test "turns the body, and the two directions disagree about where it faces", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/fly")

      view |> element("#fly-left") |> render_click()
      left = heading(view |> render())
      view |> element("#fly-reset") |> render_click()
      view |> element("#fly-right") |> render_click()
      right = heading(view |> render())

      assert left > 0
      assert right < 0
    end
  end

  # The path card prints the heading it read from the body's own rotation.
  defp heading(html) do
    [_, degrees] = Regex.run(~r/facing (-?\d+)°/, html)
    String.to_integer(degrees)
  end
end
