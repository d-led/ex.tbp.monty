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

    # What each node can do, and who can do a thing: the two directions of one
    # question, and the second is what a reader needs when an experiment needs a
    # machine this one is not.
    test "says what each node can do, and which nodes can do what", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      name = ExTbpMonty.Node.safe_name(node())

      assert view |> element("#node-" <> name) |> render() =~ "monty"
      assert view |> element("#capability-monty") |> render() =~ name
      assert view |> element("#cluster-capability-source") |> render() =~ "MONTY_CAPABILITIES"

      # Two chapters, always both: this node of the application in the first, and
      # the second saying plainly that nothing in the cluster brings plugins.
      assert render(view) =~ "Ex.Monty nodes"
      assert view |> element("#cluster-node-count") |> render() =~ "1"
      assert view |> element("#cluster-plugin-node-count") |> render() =~ "0"
      refute has_element?(view, "#cluster-plugin-node-list")
      assert render(view) =~ "No node brings plugins"
    end

    # The list is the part of the page that moves on its own: a peer joins and
    # the row appears, because a reader who has to reload to see the cluster is a
    # reader who does not believe the footer beside it.
    test "a peer that joins appears in the list while the page is open", %{conn: conn} do
      previous = Application.get_env(:ex_tbp_monty, :cluster)
      on_exit(fn -> Application.put_env(:ex_tbp_monty, :cluster, previous) end)
      Application.put_env(:ex_tbp_monty, :cluster, enabled: true, seeds: [])

      {:ok, view, _html} = live(conn, ~p"/settings")

      assert view |> element("#cluster-count") |> render() =~ "One node in this cluster"
      refute has_element?(view, "#capability-gpu")

      entries =
        ExTbpMonty.Cluster.Nodes.of(
          [node(), :"gpu@127.0.0.1"],
          fn _ -> %{version: "0.1.3", capabilities: ["gpu"]} end
        )

      Phoenix.PubSub.broadcast(
        ExTbpMonty.PubSub,
        ExTbpMonty.Cluster.Nodes.topic(),
        {:cluster_nodes, entries}
      )

      # A message to the page is a message: asking for its state is the answer
      # that everything before it has been handled.
      _ = :sys.get_state(view.pid)

      assert view |> element("#cluster-count") |> render() =~ "2 nodes in this cluster"
      # The id of a row is a node name, and a node name has a dot in it: asked
      # for as text, because `#node-gpu_127.0.0.1` is not a selector.
      assert view |> element("#cluster-node-list") |> render() =~ "gpu@127.0.0.1"
      assert view |> element("#capability-gpu") |> render() =~ "gpu@127.0.0.1"
    end
  end
end
