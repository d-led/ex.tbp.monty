defmodule ExTbpMontyWeb.ClusterPeerRuns do
  @moduledoc """
  What the other nodes have been running, under this node's own list of runs.
  Read-only, and it says so: a run's files, its worker and its page are on the
  node that owns it, so the one thing a reader can do with a row here is follow it
  to the node it belongs to (`ExTbpMonty.Cluster.Peers` asks, this draws). A row's
  state is printed beside it, so a run still going and one that settled an hour
  ago are told apart without opening either.

  A component because the list is not known when the page first draws — it is an
  `:rpc` per peer — and because a component is where a list that arrives late
  belongs. The page decides whether there is a panel to draw at all (`peer_runs`
  is `[]` until an answer comes), which is also what keeps this component's root a
  single static tag, as a stateful component's must be.
  """

  use ExTbpMontyWeb, :live_component

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <section id="peer-runs" class="space-y-2 rounded-box border border-base-300 bg-base-100 p-3">
      <h2 class="text-xs font-semibold text-base-content/60">On other nodes</h2>
      <p class="text-[11px] text-base-content/50">
        Their latest runs, their files — what this page can do with one is open it there.
      </p>
      <ul class="space-y-2 text-xs">
        <li
          :for={%{node: node, runs: runs} <- @peer_runs}
          id={"peer-" <> node.name}
          class="space-y-0.5"
        >
          <div class="flex flex-wrap items-baseline gap-2 font-mono">
            <.link :if={node.web} href={node.web} class="hover:underline" title={"Open " <> node.web}>
              {label(node)}
            </.link>
            <span :if={is_nil(node.web)}>{label(node)}</span>
            <span class="text-base-content/50">
              {length(runs)} run{count_s(length(runs))}
            </span>
          </div>
          <ul class="ms-4 space-y-0.5">
            <li :for={run <- runs} class="flex flex-wrap items-baseline gap-2">
              <.link
                :if={node.web}
                href={node.web <> "/runs/" <> run.id}
                class="link link-hover font-mono"
              >
                {run.experiment}
              </.link>
              <span :if={is_nil(node.web)} class="font-mono">{run.experiment}</span>
              <span class="text-base-content/50">{run.state} · {run.steps} steps</span>
            </li>
          </ul>
        </li>
      </ul>
    </section>
    """
  end

  defp count_s(1), do: ""
  defp count_s(_several), do: "s"

  # The node's own name — the string a peer is told, and the one a person can
  # paste — rather than the spelling its folder has. Read with `Map.get/2`: the
  # entry may be a snapshot from before the address was on it.
  defp label(node), do: Map.get(node, :address) || node.name
end
