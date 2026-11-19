defmodule FlyversePlugin.Cluster do
  @moduledoc """
  How this node reaches the studio: libcluster, configured from the environment.

  Two variables, and they are the ones a studio node reads, because one secret
  written in two spellings is a cluster that stays silently separate:

    * `MONTY_CLUSTER_SECRET` — the cookie. Set before the first connection is
      attempted, since a connection is made with whatever cookie the node holds
      at the time.
    * `MONTY_SEEDS` — the nodes to reach, comma-separated, in the spelling a
      person copies out of a peer's Settings page (`node1@10.0.0.7`).

  `MONTY_CLUSTER=1` is the third, for a node that was told to join and not told
  whom: it gossips and lets the peers announce themselves.

  ## Two topologies when there are seeds, and why both

  `Epmd` is the seed list: the studio that started this node, by the name it had
  when it was asked. `Gossip` is how that studio is found **again** after it
  restarts, and it is not a nicety: a desktop window names itself
  `monty-studio-<id>@127.0.0.1` with a fresh id on every start, so the seed this
  node was handed is a name that will never answer again. The window gossips (it
  is started with `MONTY_CLUSTER=1` and no seeds, which is libcluster's gossip
  topology), and a node that listens for it reconnects to the new name on its
  own — no poll of ours, no restart of this node, and nothing to configure.

  It is the studio's own rule (`ExTbpMonty.Cluster`) one choice wider: the studio
  takes either its seeds or gossip, because a deployment that names its peers
  knows all of them; a companion is told one name and can lose it.

  ## What is not here

  Gossip is not authenticated: libcluster's `secret` option would have to be set
  here *and* in the studio, and it is not. It announces and connects on the local
  network, which is the trust boundary this pair already shares a cookie across.
  """
  use Supervisor

  # libcluster's strategies, spelled from the top level: `Cluster` inside this
  # application means this module, so a bare `Cluster.Strategy.Gossip` would name
  # a module that does not exist.
  alias Elixir.Cluster.Strategy.{Epmd, Gossip}

  @seeds "MONTY_SEEDS"
  @secret "MONTY_CLUSTER_SECRET"
  @cluster "MONTY_CLUSTER"

  @doc false
  def start_link(options \\ []),
    do: Supervisor.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))

  @impl true
  def init(_options) do
    children =
      case topologies() do
        [] -> []
        topologies -> [{Elixir.Cluster.Supervisor, [topologies]}]
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  The libcluster topologies: the seeds, and gossip beside them.

  Empty is a normal answer — a node nobody asked to cluster — and it starts no
  supervisor and opens no socket, which is also what keeps a test run from
  joining whichever window happens to be open on the machine.
  """
  @spec topologies() :: keyword()
  def topologies do
    case seeds() do
      [] -> if cluster?(), do: [gossip: [strategy: Gossip]], else: []
      hosts -> [seeds: [strategy: Epmd, config: [hosts: hosts]], gossip: [strategy: Gossip]]
    end
  end

  @doc """
  The nodes named in `MONTY_SEEDS`, as the atoms OTP uses.

  Empty when the variable is unset or blank, which is a node that runs alone
  rather than a mistake: the same code is started in a test with no cluster at
  all.
  """
  @spec seeds() :: [node()]
  def seeds do
    @seeds
    |> System.get_env("")
    |> String.split(",", trim: true)
    # One atom per node name, made when this process starts from a value a
    # deployment wrote: the table grows by the size of the cluster, not by the
    # size of anybody's traffic.
    |> Enum.map(&(&1 |> String.trim() |> atom()))
  end

  @doc """
  The cookie, from `MONTY_CLUSTER_SECRET`, set before any topology starts.

  Read here rather than cached: a deployment hands the secret over, and a process
  that cached the first answer would ignore a change that a restart was meant to
  apply. `Node.set_cookie/1` raises on a VM that was never named, and a node
  without a name joins nothing, so an unnamed node answers `:ok` having done
  nothing.
  """
  @spec set_cookie() :: :ok
  def set_cookie do
    with true <- Node.alive?(),
         secret when secret not in [nil, ""] <- System.get_env(@secret) do
      Node.set_cookie(atom(secret))
      :ok
    else
      _unnamed_or_no_secret -> :ok
    end
  end

  # The studio's own switch, read the same way: a word, not a truthy string.
  defp cluster?, do: System.get_env(@cluster) in ["1", "true", "yes", "on"]

  # `:erlang.binary_to_atom/2` rather than `String.to_atom/1`: these are node
  # names and a cookie, written by whoever deployed this, and the explicit call
  # says the atom is deliberate.
  defp atom(text), do: :erlang.binary_to_atom(text, :utf8)
end
