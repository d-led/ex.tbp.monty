defmodule ExTbpMontyWeb.SettingsLiveTest do
  use ExTbpMontyWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Monty.Studio.Settings

  setup do
    Settings.forget()
    :ok
  end

  describe "the settings page" do
    test "is in the menu, not only at its address", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#nav-settings")
    end

    test "shows each setting against what it already is", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#setting-run_refresh_ms")
      assert view |> element("#settings_run_refresh_ms") |> render() =~ ~s(value="250")
    end

    test "saves what a reader types, and says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> form("#settings-form", settings: %{run_refresh_ms: "600"})
        |> render_submit()

      assert html =~ "Saved"
      assert Settings.get("run_refresh_ms") == 600
    end

    test "refuses a value outside the range, and keeps the old one", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> form("#settings-form", settings: %{run_refresh_ms: "1"})
        |> render_submit()

      assert html =~ "has to be between"
      assert Settings.get("run_refresh_ms") == 250
    end
  end

  # The difference the page exists to draw: a boot value is shown, because a
  # page that offered to change it would be lying — and a per-statement one is a
  # setting, because it can be passed on the statement.
  describe "this instance" do
    test "names the pool settings, and says they need a restart", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#system-Pool-size")
      assert render(view) =~ "a change needs a restart"
    end

    # What a desktop user is asked to send back when a run is slow: whether the
    # hot loops are the Rust kernels, where the writes land, and what the machine
    # is. Each of these has been guessed at wrongly in a session already.
    test "says which kernels it runs and where its writes land", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#system-Kernels")
      assert has_element?(view, "#system-Database-file")
      assert has_element?(view, "#system-Data-directory")
      assert has_element?(view, "#system-Machine")
    end

    test "offers the episode write timeout, which a restart is not needed for", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#setting-db_write_timeout_ms")
      refute has_element?(view, "#system-Database-write-timeout")
    end

    # What an instance says when its configuration declares nothing and the
    # adapter's own defaults are in force: the page has to say so rather than
    # leave a blank where a number belongs.
    test "says when a number is the adapter's default", %{conn: conn} do
      repo = ExTbpMonty.Database.repo_module()
      configured = Application.get_env(:ex_tbp_monty, repo)
      Application.put_env(:ex_tbp_monty, repo, [])
      on_exit(fn -> Application.put_env(:ex_tbp_monty, repo, configured) end)

      {:ok, view, _html} = live(conn, ~p"/settings")

      assert render(view) =~ "adapter"
    end
  end

  describe "the nodes this instance knows" do
    # The list is where "how many nodes are there, and which" is answered: the
    # footer says the count, and this is the page that names them. A node that
    # runs alone is a cluster of one — one row, marked — and, when it has no
    # name at all, the sentence that says what would give it one.
    test "a node that runs alone lists itself once and says why", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert view |> element("#cluster-count") |> render() =~ "runs alone"

      list = view |> element("#cluster-node-list") |> render()
      assert list =~ "this node"
      assert length(String.split(list, "<li")) == 2

      if ExTbpMonty.Node.distributed?() do
        refute has_element?(view, "#cluster-why-not")
      else
        assert view |> element("#cluster-why-not") |> render() =~ "--sname monty"
      end
    end

    test "the node's own name is a fact about this instance too", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#system-Node")
    end

    # The cookie is the cluster's password, so the page says where it came from
    # and never what it is: a settings screen somebody screenshots is not a place
    # to print one.
    test "says where the shared cookie comes from, and does not print it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      cookie = view |> element("#cluster-cookie") |> render()

      assert cookie =~ "cookie:"
      assert cookie =~ "cookie of the user" or cookie =~ "shares no cookie"
    end
  end
end
