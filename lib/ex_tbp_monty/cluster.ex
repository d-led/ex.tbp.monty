defmodule ExTbpMonty.Cluster do
  @moduledoc """
  Whether this node joins a cluster, and the processes that would make it one.

  Clustering is an *addition*. `config :ex_tbp_monty, :cluster, enabled: false`
  is the default in every environment, and with it `children/0` answers `[]`:
  nothing below is started, no process is named, and the tree is the one a single
  node has always had. `config/runtime.exs` turns it on from the environment —
  `MONTY_CLUSTER=1`, or a seed list in `MONTY_SEEDS` — because which nodes to
  join is a start-up decision in the same way the node's own name is
  (`ExTbpMonty.Node` is the other half of that story).

  ## What is started, and in what order

  * libcluster's supervisor, with one topology: the seeds this node was given
    (`Cluster.Strategy.Epmd`), or gossip discovery when nobody named any. It is
    what turns `Node.list/0` from empty into the peers.
  * `Horde.Registry` — `keys: :unique`, `members: :auto`: a name that belongs to
    one process in the whole cluster, reachable from a page on any node.
  * `Horde.DynamicSupervisor` — `Horde.UniformDistribution` and
    `process_redistribution: :passive`: where work that may run on another node
    is started. Passive redistribution is deliberate: a child moves when its node
    dies, not whenever the membership changes, so a node that reconnects does not
    reshuffle what is already running.

  The shape is copied from a project that runs it (`ssr-robust-live-svg`), and so
  are the two traps its notes record: a CRDT-backed registry has windows in which
  nothing by that name is running, so a caller has to be able to find nothing;
  and nodes that do not share a cookie stay silently unclustered, which is why
  `ExTbpMonty.Node.why_not/0` is put in front of a reader rather than left in a
  log.

  ## What is *not* here

  Nothing in this module decides what runs where. It is the wiring — names, a
  topology, a supervisor — and the work that uses it is a caller's decision.
  """

  # libcluster's strategies, spelled from the top level. This module is called
  # `Cluster`, and inside its own body Elixir resolves the bare `Cluster` to
  # *this* module — so `Cluster.Strategy.Epmd` here names a module that does not
  # exist, and a topology pointed at it would silently never discover a peer.
  alias Elixir.Cluster.Strategy.{Epmd, Gossip}

  # Horde's two names, in this application's namespace: a page or a test asks for
  # them rather than spelling `Horde.Registry` at the call site, and a second
  # cluster in one VM (a test) has somewhere to aim.
  @registry ExTbpMonty.Cluster.Registry
  @supervisor ExTbpMonty.Cluster.DynamicSupervisor

  @doc "The registry a cluster-wide name is looked up in."
  @spec registry() :: module()
  def registry, do: @registry

  @doc "The supervisor a cluster-wide process is started under."
  @spec supervisor() :: module()
  def supervisor, do: @supervisor

  @doc """
  Whether this node was asked to join a cluster.

  The setting, not the state: a node asked for a cluster and connected to nobody
  answers `true` here and has one node in `nodes/0`, which is a cluster of one.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(settings(), :enabled, false) == true

  @doc """
  The nodes this one was told to join, as the node names libcluster is given.

  Empty is a normal answer: gossip discovery is what a cluster of several nodes on
  one machine needs, and it needs no seed at all.
  """
  @spec seeds() :: [node()]
  def seeds, do: Keyword.get(settings(), :seeds, [])

  @doc """
  The libcluster topology: the seeds when there are some, gossip when there are
  none.

  Gossip rather than a fixed list for the single-machine case, because three
  `mix phx.server` processes started by one `process-compose` file know nothing
  about each other's names until they have heard one.
  """
  @spec topologies() :: keyword()
  def topologies do
    case seeds() do
      [] -> [default: [strategy: Gossip]]
      hosts -> [default: [strategy: Epmd, config: [hosts: hosts]]]
    end
  end

  @doc """
  The children that make this node a cluster member — an empty list when it was
  not asked to be one.

  `Application` splices this into its own tree, so a single node starts exactly
  what it started before this module existed.
  """
  @spec children() :: [Supervisor.child_spec() | {module(), term()} | module()]
  def children do
    if enabled?() do
      [
        # libcluster's own supervisor. Spelled out rather than aliased: this
        # module is called `Cluster` too, and `Cluster.Supervisor` would be a
        # guess about which one it means.
        {Elixir.Cluster.Supervisor, [topologies()]},
        {Horde.Registry, [name: @registry, keys: :unique, members: :auto]},
        {Horde.DynamicSupervisor,
         [
           name: @supervisor,
           strategy: :one_for_one,
           distribution_strategy: Horde.UniformDistribution,
           process_redistribution: :passive,
           members: :auto,
           max_restarts: 90,
           max_seconds: 30
         ]},
        # And the list a page reads: which nodes there are, and which build each
        # one runs. Last because it is the only one that asks the others
        # anything — it must not start before there is a cluster to ask about.
        ExTbpMonty.Cluster.Nodes
      ]
    else
      []
    end
  end

  @doc """
  The cluster as a page should tell it: this node first, then the peers this node
  is connected to now.

  This node is always in the list, and it is the only member of a cluster of one —
  a normal state, not a fault, and what every node is before its peers connect.
  """
  @spec nodes() :: [node()]
  def nodes, do: [node() | Node.list()]

  defp settings, do: Application.get_env(:ex_tbp_monty, :cluster, [])
end
