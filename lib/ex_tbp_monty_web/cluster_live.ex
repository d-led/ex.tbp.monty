defmodule ExTbpMontyWeb.ClusterLive do
  @moduledoc """
  The one thing a page has to do to stay honest about the cluster: hear the
  change, and hand it to the components that show it.

  `Phoenix.PubSub` delivers to a process — the page's own — and a `LiveComponent`
  has no `handle_info/2` of its own (the module's own documentation says so: the
  parent must receive and `send_update/3`). So every LiveView in this application
  mounts with this hook: it subscribes the page to `Cluster.Nodes.topic/0`, and
  when the poller says the list changed it hands the list to each component that
  draws it — the footer's count and the settings page's list.

  Both are sent every time, and `send_update/3` for a component the page does not
  render does nothing: the footer is on every page and the list only on one, and
  one hook serving both is what keeps a page from having to say which it is.

  Nothing happens on a node that was not asked to cluster, and nothing before the
  socket connects: a dead render has no listener, and the render it produces is
  already the current answer.
  """

  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, send_update: 2]

  alias ExTbpMonty.Cluster

  @showing_the_list [
    {ExTbpMontyWeb.ClusterBadge, "cluster-badge"},
    {ExTbpMontyWeb.ClusterNodes, "cluster-nodes"}
  ]

  @doc """
  The mount hook every LiveView gets: subscribe to the cluster, once, on the
  connected socket.
  """
  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) and Cluster.enabled?() do
      Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Cluster.Nodes.topic())

      {:cont, attach_hook(socket, :cluster_nodes, :handle_info, &hand_on/2)}
    else
      {:cont, socket}
    end
  end

  # The message is this hook's own and stops here: a page that knows nothing about
  # the cluster has no `handle_info` clause for it, and passing it on would be a
  # crash for the sake of a badge.
  defp hand_on({:cluster_nodes, nodes}, socket) do
    Enum.each(@showing_the_list, fn {module, id} -> send_update(module, id: id, nodes: nodes) end)

    {:halt, socket}
  end

  defp hand_on(_other, socket), do: {:cont, socket}
end
