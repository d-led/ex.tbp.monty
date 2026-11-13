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

  defp configure(settings), do: Application.put_env(:ex_tbp_monty, :cluster, settings)
end
