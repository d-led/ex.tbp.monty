defmodule FlyversePlugin.Join do
  @moduledoc """
  What this node is in a cluster *with*, said out loud.

  libcluster connects (`FlyversePlugin.Cluster`); this process is the line a
  person reads afterwards. It is not a poller: `:net_kernel` already knows when a
  peer arrives or leaves, so this process is told rather than asking.

  The state is logged once at boot and then only on a change, because a studio
  node takes longer to boot than this one and a plugin that shouted about a node
  that was still compiling would make the interesting lines unfindable. The
  first line is logged whatever it found: a node that is in no cluster is the
  failure nobody can see — it runs, it answers `rpc`, and every page says one
  node.
  """

  use GenServer

  require Logger

  @variable "MONTY_SEEDS"

  @doc false
  def start_link(options \\ []),
    do: GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))

  @impl true
  def init(_options) do
    # `node_type: :all` so a peer that hides itself (`-hidden`) is still reported:
    # this process exists to say who is here, not who is visible. An unnamed VM
    # has no distribution to monitor, and a node that never joined one is the
    # case this sentence is for rather than an error.
    if Node.alive?(), do: :net_kernel.monitor_nodes(true, node_type: :all)

    reached = reached()
    Logger.info("flyverse plugin: #{describe(reached)}")

    {:ok, reached}
  end

  @impl true
  def handle_info({kind, _node, _info}, reached) when kind in [:nodeup, :nodedown] do
    now = reached()

    if now != reached, do: Logger.info("flyverse plugin: #{describe(now)}")

    {:noreply, now}
  end

  @doc """
  The nodes this one is connected to, in the words the log uses.

  A cluster of one is a node that answers and has joined nothing, which is what
  the empty list has to say: `nil` would read as "not known yet".
  """
  @spec describe([node()]) :: String.t()
  def describe([]),
    do: "not in a cluster (no seed answered #{@variable}, and no window announced itself)"

  def describe(reached),
    do: "in a cluster with #{Enum.map_join(reached, ", ", &to_string/1)}"

  defp reached, do: Node.list() |> Enum.sort()
end
