defmodule ExTbpMontyWeb.ClusterBadge do
  @moduledoc """
  How many nodes there are, in the footer of every page, and it keeps itself up to
  date.

  A component rather than a line in the layout, because of *who* has to hear the
  news. `Phoenix.PubSub` delivers to a process, and the process a page's footer
  runs in is the page's own: a bare `<a>` in the layout would only change when
  something else made the page render again. A `LiveComponent` subscribes in
  `update/2` and has its own `handle_info/2`, so a peer joining re-renders the
  badge and nothing else — no page has to know the cluster exists.

  The list itself is `ExTbpMonty.Cluster.Nodes`: a poller, because asking a peer
  for its build is an `:rpc` call that a dead node answers slowly. Phoenix's
  default pubsub adapter is the distributed one, so the message crosses nodes —
  a page on one node hears about a peer that joined another. Nothing is
  subscribed on a node that was not asked to cluster: the layout does not render
  this badge at all there.

  ## How the list reaches it

  A component has no `handle_info/2` of its own, so the page receives the
  broadcast and hands it on with `send_update/3` — `ExTbpMontyWeb.ClusterLive` is
  the mount hook that does that for every page. That is also why `update/2` takes
  `nodes` as an assign when it is given one, and asks the poller otherwise: a
  re-render that was not about the cluster must not freeze the badge at an old
  list.
  """

  use ExTbpMontyWeb, :live_component

  alias ExTbpMonty.Cluster

  @impl true
  def update(assigns, socket) do
    nodes = assigns[:nodes] || Cluster.Nodes.snapshot()

    {:ok, socket |> assign(assigns) |> assign(:nodes, nodes)}
  end

  # A component is never handed a message it did not ask for: the page forwards
  # the cluster's news with `send_update/3`, which lands in `update/2`.
  @impl true
  def render(assigns) do
    ~H"""
    <a
      id="cluster-nodes"
      href={~p"/settings"}
      title={Enum.map_join(@nodes, ", ", &"#{&1.name} #{&1.version || "no answer"}")}
      class="inline-flex items-center gap-1 hover:opacity-70"
    >
      <.icon name="hero-server-stack-mini" class="size-3.5" />
      <span class="font-mono">{count(@nodes)}</span>
    </a>
    """
  end

  # "1 node" and "3 nodes": one token with its number, like the durations.
  defp count(nodes) when length(nodes) == 1, do: "1 node"
  defp count(nodes), do: "#{length(nodes)} nodes"
end
