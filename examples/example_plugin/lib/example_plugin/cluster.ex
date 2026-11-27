defmodule ExamplePlugin.Cluster do
  @moduledoc """
  How this node reaches a studio: libcluster, configured from the environment.

  Two variables, and they are the ones a studio node reads, because one secret
  written in two spellings is a cluster that stays silently separate:

    * `MONTY_CLUSTER_SECRET` — the cookie. Set before any connection is
      attempted, since a connection is made with whatever cookie the node holds
      at the time.
    * `MONTY_SEEDS` — the nodes to reach, comma-separated, in the spelling a
      person copies out of a peer's Settings page (`node1@10.0.0.7`).

  ## Seeds, and nothing else

  A seed is dialled; nothing is discovered. There is no gossip here on purpose:
  this node and a studio are separate clusters until somebody connects them, and
  a node that announced itself would let a studio that happens to be open on the
  same machine join itself to this one without anyone asking. Whoever wants the
  two together dials the other side — the studio from **Settings → Cluster →
  Connect to a node**, which is a `Node.connect/1` and leaves the choice with a
  person.

  A node with no seeds is therefore a cluster of one, which is the arrangement a
  test and a hand-started `mix run --no-halt` both get.
  """
  use Supervisor

  # libcluster's strategy, spelled from the top level: `Cluster` inside this
  # application means this module, so a bare `Cluster.Strategy.Epmd` would name
  # a module that does not exist.
  alias Elixir.Cluster.Strategy.Epmd

  @seeds "MONTY_SEEDS"
  @secret "MONTY_CLUSTER_SECRET"
  # How often a seed that is not answering is dialled again, in milliseconds.
  @redial 5_000

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
  The libcluster topologies: the seeds, and nothing beside them.

  Empty is a normal answer — a node that was told to join nothing — and it
  starts no supervisor and opens no socket, which is what keeps this node a
  cluster of one, and keeps a test run from joining whichever window happens to
  be open on the machine.

  The seeds are **re-dialled**, which is not the strategy's default:
  `Cluster.Strategy.Epmd` connects its hosts once in `init/1` and then sleeps for
  `config[:timeout]`, whose default is `:infinity`. A host started before the
  studio — the common case, since a plugin host has no HTTP to wait for — is then
  invisible for the rest of its life, and so is one whose studio restarted; the
  studio's answer is "no node in this cluster says it hosts plugins", which reads
  like a host that is down while the host is up and answering.
  """
  @spec topologies() :: keyword()
  def topologies do
    case seeds() do
      [] -> []
      hosts -> [seeds: [strategy: Epmd, config: [hosts: hosts, timeout: @redial]]]
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

  # `:erlang.binary_to_atom/2` rather than `String.to_atom/1`: these are node
  # names and a cookie, written by whoever deployed this, and the explicit call
  # says the atom is deliberate.
  defp atom(text), do: :erlang.binary_to_atom(text, :utf8)
end
