defmodule ExTbpMontyWeb.ClusterChromeTest do
  @moduledoc """
  What the chrome says about the cluster, and what a node that runs alone says:
  nothing.

  The switch is application configuration, so these cases cannot run beside a case
  that expects the other answer — `async: false`, and each one puts the setting
  back.
  """

  use ExTbpMontyWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Monty.Studio.RunHistory

  defp record(attributes) do
    {:ok, run} =
      RunHistory.start(
        Map.merge(
          %{experiment: "tutorial/first_experiment", source: "monty", steps: 3},
          attributes
        )
      )

    run
  end

  setup do
    previous = Application.get_env(:ex_tbp_monty, :cluster)
    on_exit(fn -> Application.put_env(:ex_tbp_monty, :cluster, previous) end)

    :ok
  end

  test "a node that runs alone shows no cluster badge", %{conn: conn} do
    configure(enabled: false, seeds: [])

    {:ok, view, _html} = live(conn, ~p"/settings")

    # Not a badge saying "1 node": the chrome of every page is no place for a
    # setting nobody turned on. The settings page is where it is said.
    refute has_element?(view, "#cluster-nodes")
  end

  test "a node in a cluster says how many there are, on every page", %{conn: conn} do
    configure(enabled: true, seeds: [])

    {:ok, view, _html} = live(conn, ~p"/settings")

    assert view |> element("#cluster-nodes") |> render() =~ "1 node"
    assert has_element?(view, "#cluster-nodes[title]")
  end

  test "a page hears a peer join while it is open", %{conn: conn} do
    configure(enabled: true, seeds: [])

    {:ok, view, _html} = live(conn, ~p"/settings")
    assert view |> element("#cluster-nodes") |> render() =~ "1 node"

    # Exactly what the poller announces when the list changes, delivered the way
    # it delivers it: the page re-renders on it, which is how the footer follows a
    # node joining without anybody reloading.
    entries =
      ExTbpMonty.Cluster.Nodes.of([node(), :"peer@127.0.0.1"], fn _ -> %{version: "0.1.3"} end)

    Phoenix.PubSub.broadcast(
      ExTbpMonty.PubSub,
      ExTbpMonty.Cluster.Nodes.topic(),
      {:cluster_nodes, entries}
    )

    # PubSub delivery is a message to the LiveView, so the assertion has to be
    # after the LiveView has handled it: asking for its state is the answer that
    # everything before it has been processed, and it is not a sleep.
    _ = :sys.get_state(view.pid)

    assert view |> element("#cluster-nodes") |> render() =~ "2 nodes"
    assert view |> element("#cluster-nodes") |> render() =~ "peer_127.0.0.1"
  end

  test "the runs table says where a run started and where it runs", %{conn: conn} do
    configure(enabled: true, seeds: [])
    run = record(%{node: "peer_127.0.0.1", started_on: "this_1"})

    {:ok, view, _html} = live(conn, ~p"/runs")

    # Two questions, because with one runs table for a cluster they have two
    # answers: a run asked for here and performed there is the cluster working,
    # and a single "node" column could only have said half of it.
    assert view |> element("#started-on-#{run.id}") |> render() =~ "this_1"
    assert view |> element("#node-#{run.id}") |> render() =~ "peer_127.0.0.1"
  end

  test "a run still on the node it was asked for says so without a claim's mark", %{conn: conn} do
    configure(enabled: true, seeds: [])
    run = record(%{node: "this_1", started_on: "this_1"})

    {:ok, view, _html} = live(conn, ~p"/runs")

    refute has_element?(view, "#node-#{run.id}.underline")
  end

  test "a row from before the column existed started where it runs", %{conn: conn} do
    configure(enabled: true, seeds: [])
    run = record(%{node: "this_1"})

    {:ok, view, _html} = live(conn, ~p"/runs")

    assert view |> element("#started-on-#{run.id}") |> render() =~ "this_1"
  end

  defp configure(settings), do: Application.put_env(:ex_tbp_monty, :cluster, settings)

  # The list is drawn from whatever it is given, and a peer is a place a reader
  # can go: its name is a link to the address it advertised. This node's own name
  # is text, because a link to the page a reader is already on is not a link.
  describe "a node's name in the list" do
    test "is a link to the address a peer advertised" do
      html = render_component(ExTbpMontyWeb.ClusterNodes, %{id: "cluster-nodes", nodes: [peer()]})

      [link] = html |> LazyHTML.from_fragment() |> LazyHTML.query("a") |> Enum.to_list()

      # The node's own name, not the spelling its folder has: `gpu@127.0.0.1` is
      # what a person copies into MONTY_SEEDS, and `gpu_127.0.0.1` is only what a
      # path allows. Asked for by text rather than by an id built from the name: a
      # node name carries a dot, and `#node-gpu_127.0.0.1` is not a selector.
      assert LazyHTML.text(link) |> String.trim() == "gpu@127.0.0.1"
      assert LazyHTML.attribute(link, "href") == ["http://127.0.0.1:4002"]
      assert LazyHTML.attribute(link, "class") |> List.first() =~ "select-all"
    end

    # The snapshot is a cache in `:persistent_term`, rewritten only when the list
    # changes — so after a code change it can hold entries of the shape it had
    # before. A page draws what it is given rather than raising at it.
    test "is the folder spelling when the entry predates the address" do
      html =
        render_component(ExTbpMontyWeb.ClusterNodes, %{
          id: "cluster-nodes",
          nodes: [peer() |> Map.delete(:address)]
        })

      assert html =~ "gpu_127.0.0.1"
    end

    test "is text when the node is this one, or has no address to link to" do
      html =
        render_component(ExTbpMontyWeb.ClusterNodes, %{
          id: "cluster-nodes",
          nodes: [%{peer() | self: true}, %{peer() | name: "quiet_1", web: nil, node: :quiet@1}]
        })

      assert html |> LazyHTML.from_fragment() |> LazyHTML.query("a") |> Enum.to_list() == []
    end

    # The tags say a machine hosts plugins; a reader's next question is which.
    # The list is what the poller's own answer carried, so the component asks
    # nothing and no plugin is called to draw a page. The name is the part a run
    # asks for, so it is what the line says first; the kind follows in brackets.
    test "a node that brings plugins names them" do
      html =
        render_component(ExTbpMontyWeb.ClusterNodes, %{
          id: "cluster-nodes",
          nodes: [plugin_host()]
        })

      offered = offered_by(html, "plugins-example_plugin_127.0.0.1")

      assert offered =~ "first_object" and offered =~ "(experiment)"
      assert offered =~ "follow_chamfers" and offered =~ "(motor_policy)"
    end

    # A node is a machine and a plugin is a piece fitted into one, and the page
    # says so before it says anything else about either.
    test "a node is drawn as a server, and each plugin it offers as a puzzle piece" do
      html =
        render_component(ExTbpMontyWeb.ClusterNodes, %{
          id: "cluster-nodes",
          nodes: [plugin_host(), peer()]
        })

      document = LazyHTML.from_fragment(html)

      assert Enum.count(LazyHTML.query(document, ".hero-server")) == 2
      assert Enum.count(LazyHTML.query(document, ".hero-puzzle-piece")) == 2
    end

    test "a node with no plugins to show gets no line" do
      html = render_component(ExTbpMontyWeb.ClusterNodes, %{id: "cluster-nodes", nodes: [peer()]})

      refute html =~ "plugins-"
    end

    defp plugin_host do
      Map.merge(peer(), %{
        node: :"example_plugin@127.0.0.1",
        name: "example_plugin_127.0.0.1",
        address: "example_plugin@127.0.0.1",
        web: nil,
        capabilities: ["plugin", "plugin:experiment", "plugin:motor_policy"],
        plugins: [
          %{"kind" => "experiment", "name" => "first_object"},
          %{"kind" => "motor_policy", "name" => "follow_chamfers"}
        ]
      })
    end

    # The id carries a dot, and `#plugins-example_plugin_127.0.0.1` is not a
    # selector — the same reason the node's own name is asked for by text.
    defp offered_by(html, id) do
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([id="#{id}"]))
      |> LazyHTML.text()
    end

    defp peer do
      %{
        node: :"gpu@127.0.0.1",
        name: "gpu_127.0.0.1",
        address: "gpu@127.0.0.1",
        version: "0.1.3",
        self: false,
        alive: true,
        capabilities: ["gpu", "monty"],
        web: "http://127.0.0.1:4002"
      }
    end
  end

  # What the other nodes have been running: read-only, and each run is a link to
  # the place the run actually is — the peer's own page for it.
  describe "what the other nodes have been running" do
    test "a peer's run is named and links to the peer's own page for it" do
      html =
        render_component(ExTbpMontyWeb.ClusterPeerRuns, %{
          id: "peer-runs-panel",
          peer_runs: [
            %{
              node: peer(),
              runs: [
                %{
                  id: "11111111-1111-1111-1111-111111111111",
                  experiment: "base_config_10distinctobj_dist_agent",
                  state: "running",
                  steps: 41
                }
              ]
            }
          ]
        })

      document = LazyHTML.from_fragment(html)

      assert html =~ "On other nodes"

      # Two places to go: the node, and the run on that node. Nothing here acts on
      # the run itself — its files and its worker are there.
      assert document |> LazyHTML.query("a") |> Enum.map(&LazyHTML.attribute(&1, "href")) == [
               ["http://127.0.0.1:4002"],
               ["http://127.0.0.1:4002/runs/11111111-1111-1111-1111-111111111111"]
             ]

      assert html =~ "running · 41 steps"
    end

    # Whether there is a panel at all is the page's decision, so a page with no
    # peers to report has no heading over an empty list. `@cluster_mode` is off
    # here, which is the same "nothing to report" a cluster of one gives.
    test "a node that runs alone draws no such panel", %{conn: conn} do
      configure(enabled: false, seeds: [])

      {:ok, view, _html} = live(conn, ~p"/runs")

      refute has_element?(view, "#peer-runs")
    end
  end
end
