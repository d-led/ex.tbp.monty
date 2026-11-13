defmodule ExTbpMontyWeb.ClusterNodes do
  @moduledoc """
  The cluster: which nodes there are, which build each one runs, what each one can
  do — and, under it, each capability tag above the nodes that have it.

  Two lists rather than one, because a cluster can hold two kinds of node: the
  nodes of Elixir Monty Studio (this application, running its own modules) and the
  nodes that bring **plugins** — modules this checkout does not carry. The line
  between them is the tags, not a guess: a node says it provides a plugin with a
  `plugin` tag (`ExTbpMonty.Cluster.Capabilities.plugin?/1`), and every other node
  is an Ex.Monty node. A node is in exactly one list, so a reader can count what a
  cluster is made of without adding two lists up.

  Every name here is the node's **own** — `node1@10.0.0.7` — because that is the
  string a person copies into `MONTY_SEEDS` on the next machine, and it is
  selectable for exactly that reason. The folder spelling (`node1_10.0.0.7`) is
  not shown: it is what a path allows, not what a peer dials.

  Both directions of one question, because a heterogeneous cluster is one where
  the answer differs per node: a node's row says what that machine is, and the
  list under it says who can do a thing, which is what a reader needs when an
  experiment needs a machine this one is not.

  ## Why a component

  The list changes while the page is open, and the same reason as the footer's
  `ExTbpMontyWeb.ClusterBadge` applies: `Phoenix.PubSub` delivers to a process,
  and a component has no `handle_info/2` of its own — the parent receives and
  `send_update/3`s it. `ExTbpMontyWeb.ClusterLive` is the mount hook every page
  gets, and it hands the poller's announcement to both components by id; one that
  a page does not render is not there to update, which is why one hook serves
  both.

  A node that runs alone is a cluster of one here too: the component asks
  `ExTbpMonty.Cluster.Nodes.snapshot/0`, which answers with this node on a VM that
  never started a poller. That is what the settings page shows on every
  deployment — the footer's badge is the one that is hidden when clustering is
  off.
  """

  use ExTbpMontyWeb, :live_component

  alias ExTbpMonty.Cluster
  alias ExTbpMonty.Cluster.Capabilities

  @impl true
  def update(assigns, socket) do
    nodes = assigns[:nodes] || Cluster.Nodes.snapshot()
    {plugins, own} = Enum.split_with(nodes, &Capabilities.plugin?/1)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       summary: summary(nodes),
       own: own,
       plugins: plugins,
       capabilities: Capabilities.by_tag(nodes)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-1">
      <p id="cluster-count" class="text-xs text-base-content/70">{@summary}</p>

      <.group
        id="cluster-node-list"
        count_id="cluster-node-count"
        title="Ex.Monty nodes"
        nodes={@own}
        empty="No node of this application is in the cluster."
      />

      <.group
        id="cluster-plugin-node-list"
        count_id="cluster-plugin-node-count"
        title="Ex.Monty.Plugin nodes"
        nodes={@plugins}
        empty="No node brings plugins: none advertises a `plugin` tag."
      />

      <%!--
        The other direction of the same question. A node's row says what it can
        do; this says who can do a thing — and it is the only place where a tag
        two nodes spell differently shows up as a tag with one node under it.
      --%>
      <div :if={@capabilities != []} class="space-y-0.5 pt-1">
        <p class="text-xs text-base-content/60">What this cluster can do</p>
        <ul id="cluster-capabilities" class="space-y-0.5 text-xs">
          <li
            :for={{tag, names} <- @capabilities}
            id={"capability-" <> ExTbpMonty.Node.safe_name(tag)}
            class="flex flex-wrap items-baseline gap-2"
          >
            <span class="font-mono text-base-content/70">{tag}</span>
            <span class="truncate text-base-content/50">{Enum.join(names, ", ")}</span>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :count_id, :string, required: true
  attr :title, :string, required: true
  attr :nodes, :list, required: true
  attr :empty, :string, required: true

  # One chapter: what the group is, how many nodes are in it, and the nodes.
  defp group(assigns) do
    ~H"""
    <div class="space-y-0.5">
      <p class="text-xs font-medium text-base-content/80">
        {@title}
        <span id={@count_id} class="font-normal text-base-content/50">{length(@nodes)}</span>
      </p>
      <ul :if={@nodes != []} id={@id} class="space-y-0.5 ps-2 text-xs">
        <li
          :for={entry <- @nodes}
          id={"node-" <> entry.name}
          class="flex flex-wrap items-baseline gap-2 font-mono"
        >
          <%!--
            A peer is a place a reader can go: its name is a link to the page it
            answers on, which is the address it advertised. This node's own name
            is text — a link to the page a reader is already on is not a link.
            Either way the name is the node's own, and `select-all` is there
            because the reason to read it is to paste it elsewhere.
          --%>
          <.link
            :if={entry.web && not entry.self}
            href={entry.web}
            class={["truncate select-all hover:underline", not entry.alive && "text-base-content/50"]}
            title={"Open " <> entry.web <> " — or copy the name into MONTY_SEEDS"}
          >
            {name(entry)}
          </.link>
          <span
            :if={is_nil(entry.web) || entry.self}
            class={["truncate select-all", not entry.alive && "text-base-content/50"]}
            title={hint(entry)}
          >
            {name(entry)}
          </span>
          <span class="text-base-content/50">{entry.version || "no answer"}</span>
          <span :if={entry.self} class="badge badge-xs badge-ghost">this node</span>
          <span class="text-base-content/40">{Enum.join(entry.capabilities, " ")}</span>
        </li>
      </ul>
      <p :if={@nodes == []} class="ps-2 text-xs text-base-content/50">{@empty}</p>
    </div>
    """
  end

  # The node's own name — the string its peers are told, and the one a person
  # pastes into `MONTY_SEEDS`. A VM that was never named has none, and saying so
  # is truer than printing the spelling its folder had to resort to:
  # `nonode_nohost` is not a node anybody can dial.
  #
  # `Map.get/2` rather than `entry.address`, because the list a page draws can be
  # a snapshot from before this field existed: `Cluster.Nodes` keeps the last poll
  # in `:persistent_term` and rewrites it on a change, so a code change with no
  # peer joining leaves an entry of the old shape in place. A page draws what it
  # is given rather than raising at it.
  defp name(entry), do: Map.get(entry, :address) || "unnamed"

  defp hint(entry) do
    case Map.get(entry, :address) do
      nil -> "This VM was started without a node name: --name node1@host gives it one."
      address -> "Copy this into MONTY_SEEDS, or pass it to --name: #{address}"
    end
  end

  # The one sentence that says which case a reader is in, because "one node" is
  # three different situations: clustering off, a cluster of one, and a cluster
  # that happens to have one member up.
  defp summary(nodes) do
    case {Cluster.enabled?(), length(nodes)} do
      {false, _} ->
        "This instance runs alone: clustering is off, and MONTY_CLUSTER (with a node name) turns it on."

      {true, 1} ->
        "One node in this cluster — this one. A peer appears here as soon as it connects."

      {true, count} ->
        "#{count} nodes in this cluster, this one first."
    end
  end
end
