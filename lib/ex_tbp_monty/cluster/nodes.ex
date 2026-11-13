defmodule ExTbpMonty.Cluster.Nodes do
  @moduledoc """
  Which nodes are in this cluster, what they are called and which build they run.

  The list is *polled and cached*, and that is the whole reason this is a process:
  asking a peer for its version is an `:rpc.call/5`, and a peer that has just
  died answers nothing for as long as the node table takes to notice — long
  enough that a page which asked on render would hang behind it. So one process
  asks, every few seconds, and a page reads the answer it already has.

  A node that runs alone has no process at all (`cluster mode` is a start-up
  decision, and `ExTbpMonty.Cluster.children/0` is empty when it was not asked
  for) — and `snapshot/0` still answers, with the one entry a cluster of one has:
  this node. That keeps every caller free of "is there a poller" branching.

  ## What an entry is

      %{node: :monty@10.0.0.7, name: "monty_10.0.0.7", self: true,
        version: "0.1.3", capabilities: ["gpu", "monty"], alive: true}

  `name` is the node's name made safe for a path — the same name its data folder
  carries (`ExTbpMonty.Node.safe_name/1`), so a reader who sees a node in this
  list and a folder on disk is looking at one thing and not two. A peer that did
  not answer is `alive: false` with no version, which is the difference between
  "there is a node I cannot reach" and "there is no node".

  `capabilities` travel with the version because both come from the same `:rpc`
  (`identity/0`) and both are answers to "what is that node": a heterogeneous
  cluster is one where the tags decide which node a run may go to, and a node
  whose tags cost a second round trip would be a list that is half up to date.
  `ExTbpMonty.Cluster.Capabilities` is the vocabulary.
  """

  use GenServer

  require Logger

  alias ExTbpMonty.{Cluster, Node}
  alias ExTbpMonty.Cluster.Capabilities

  @poll_ms 3_000

  # How long a peer has to answer. Short on purpose: the poller is the only
  # caller, it repeats, and a page is never waiting behind it.
  @probe_ms 500

  # Where a change to the list is announced. Phoenix's default pubsub adapter is
  # `Phoenix.PubSub.PG2`, which reaches every connected node, so a page on one
  # node hears about a peer that joined another.
  @topic "cluster:nodes"

  @doc "The topic a page subscribes to hear the list change."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "The cluster as a list, this node first."
  @spec snapshot() :: [map()]
  def snapshot do
    case poller() do
      nil -> of(Cluster.nodes())
      pid -> GenServer.call(pid, :snapshot)
    end
  end

  @doc "How many nodes there are — one on a node that runs alone."
  @spec count() :: pos_integer()
  def count, do: length(snapshot())

  @doc """
  The entries for `nodes`, asking each for its version.

  Public because a test asks it directly: `of/2` is where the shape is decided,
  and a fetcher a test passes in is the only way to see two nodes without two
  VMs.
  """
  @spec of([node()], (node() -> map() | nil)) :: [map()]
  def of(nodes, fetch \\ &ask/1) do
    nodes
    |> Enum.uniq()
    |> Enum.map(fn name ->
      # This node answers itself: an `:rpc` hop to ask a VM about itself is a hop
      # for nothing, and the fetcher is not called for it either.
      answer = if name == node(), do: identity(), else: fetch.(name)
      version = version_of(answer)

      %{
        node: name,
        name: Node.safe_name(name),
        self: name == node(),
        version: version,
        capabilities: capabilities_of(answer),
        alive: is_binary(version)
      }
    end)
    |> Enum.sort_by(&{not &1.self, &1.name})
  end

  @doc """
  The nodes that offer `tag` — the question a scheduler asks, and the one a
  reader asks when an experiment needs a machine this one is not.

  Asked in any spelling (`ExTbpMonty.Cluster.Capabilities.offers?/2`), and `[]`
  when no node has it, which is an answer and not a fault: a cluster of one that
  was given a GPU-less machine has no `gpu` in it.
  """
  @spec offering(String.t() | atom()) :: [map()]
  def offering(tag) do
    Enum.filter(snapshot(), &Capabilities.offers?(&1.capabilities, tag))
  end

  @doc """
  What this node tells a peer that asks: its node name, the build it runs and
  what it can do.

  Called by `:rpc` from another node's poller, so it must stay cheap and must not
  touch anything a page owns.
  """
  @spec identity() :: %{node: node(), version: String.t(), capabilities: [String.t()]}
  def identity do
    %{node: node(), version: version(), capabilities: Capabilities.declared()}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # The first list is ready before the first page asks for it: a page opened on
    # a node that just started would otherwise wait for a poll it did not start.
    state = poll()
    schedule()

    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  @impl true
  def handle_info(:poll, state) do
    schedule()
    entries = poll()

    # Said only when it changed: a page that re-rendered every three seconds for
    # nothing would be a page that never stops working.
    if entries != state, do: announce(entries)

    {:noreply, entries}
  end

  defp announce(entries) do
    Phoenix.PubSub.broadcast(ExTbpMonty.PubSub, @topic, {:cluster_nodes, entries})
  end

  defp schedule, do: Process.send_after(self(), :poll, @poll_ms)

  defp poll do
    of([node() | Node.peers()])
  rescue
    # A list is not worth a crash: the node this failed on is still the node with
    # the page, and the next poll is three seconds away.
    error ->
      Logger.warning("cluster nodes: could not list the nodes: #{inspect(error)}")

      of([node()])
  end

  defp poller do
    case Process.whereis(__MODULE__) do
      nil -> nil
      pid -> pid
    end
  end

  # The version on a node that is not there is `nil`, which is what `alive:
  # false` means.
  defp ask(name) do
    case :rpc.call(name, __MODULE__, :identity, [], @probe_ms) do
      %{} = answer -> answer
      _unreachable -> nil
    end
  end

  defp version_of(%{} = answer), do: answer[:version]
  defp version_of(_no_answer), do: nil

  # A peer running a build older than the tag vocabulary says nothing about its
  # capabilities, and an entry with none is the honest reading: it can be given
  # the work that asks for nothing in particular.
  defp capabilities_of(%{} = answer), do: Capabilities.of_entry(answer)
  defp capabilities_of(_no_answer), do: []

  defp version do
    case Application.spec(:ex_tbp_monty, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end
end
