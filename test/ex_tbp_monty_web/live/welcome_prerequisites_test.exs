defmodule ExTbpMontyWeb.WelcomePrerequisitesTest do
  # The prerequisites are addressed by environment variables, which are the
  # machine's, so these cannot run beside anything else that reads them.
  use ExTbpMontyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Monty.Prerequisites
  alias Monty.Test.PrerequisiteRoots

  describe "the front door on a machine with no data yet" do
    @tag :tmp_dir
    test "says which bundles a run needs, and links to the page that fetches them", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      PrerequisiteRoots.with_roots(tmp_dir, fn ->
        {:ok, view, _html} = live(conn, ~p"/")

        assert has_element?(view, "#welcome-missing-data")
        assert has_element?(view, "#welcome-missing-data-link")

        said = view |> element("#welcome-missing-data") |> render()

        assert said =~ "not on this machine yet"
        # The page names the bundles, so a reader knows what is being asked of
        # them rather than only that something is.
        assert said =~ hd(Prerequisites.all()).title
      end)
    end

    @tag :tmp_dir
    test "says nothing once the volume has every bundle", %{conn: conn, tmp_dir: tmp_dir} do
      PrerequisiteRoots.with_roots(tmp_dir, fn ->
        for prerequisite <- Prerequisites.all(), do: PrerequisiteRoots.plant(prerequisite)

        {:ok, view, _html} = live(conn, ~p"/")

        refute has_element?(view, "#welcome-missing-data")
      end)
    end
  end
end
