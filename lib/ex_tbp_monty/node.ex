defmodule ExTbpMonty.Node do
  @moduledoc """
  Whether this node is a member of a cluster, what it is called, and — when it is
  not — what would make it one.

  Clustering is a start-up decision: a BEAM node is named before the application
  starts, or not at all, and nothing can turn a `:nonode@nohost` into a cluster
  member afterwards. So everything here reads the environment, at the moment it is
  asked, and reports what the boot did with it. `rel/env.sh.eex` is the other half:
  it is where `NODE_NAME`, `RELEASE_NODE` and the platform variables (Fly,
  Kubernetes) become the node the VM starts as.

  ## Why a page asks

  Plugins — other nodes' experiments, learning modules and motor policies — are
  found through a cluster. On a single node the list of them is not "empty": it is
  "this node is not in a cluster", which is a different sentence and a different
  fix. Anything that lists plugins asks this module first, so the two cannot be
  confused.

  ## The variables

  | variable | what it decides |
  | --- | --- |
  | `NODE_NAME` | the node's name, e.g. `monty@10.0.0.7` (the alias the release's `RELEASE_NODE` is set from) |
  | `NODE_COOKIE` | the cookie peers must share (the alias for the release's `RELEASE_COOKIE`) |
  | `RELEASE_DISTRIBUTION` | `name`, `sname` or `none` — how the release was told to start |
  | `DNS_CLUSTER_QUERY` | the name `DNSCluster` resolves to find peers |
  | `PLUGIN_SCOPE` | which `:pg` scope plugins register in |
  | `PLUGIN_DISCOVERY` | `pg` or `none` — whether this node joins one at all |

  A development server is started with a name of its own:

      elixir --sname monty -S mix phx.server

  which is the same decision `NODE_NAME` makes for a release, said to `mix`.
  """

  @doc """
  Whether the VM is a named node — the only condition under which another node
  can connect at all.
  """
  @spec distributed?() :: boolean()
  def distributed?, do: node() != :nonode@nohost

  @doc "The node's name, or `:nonode@nohost` when it has none."
  @spec name() :: node()
  def name, do: node()

  @doc """
  The peers this node is connected to now.

  Empty on a distributed node with nothing else running is a normal state, not a
  fault: a cluster of one is what a single-machine deployment is.
  """
  @spec peers() :: [node()]
  def peers, do: Node.list()

  @doc """
  What to tell somebody whose node is not in a cluster: the variable, the value it
  needs, and the `mix` line that does the same thing for a development server.

  `nil` on a distributed node, because there is nothing to say.
  """
  @spec why_not() :: String.t() | nil
  def why_not do
    if distributed?() do
      nil
    else
      "this node was not started with a name, so no other node can connect to it. " <>
        "A release takes NODE_NAME (or RELEASE_NODE), and a development server is " <>
        "`elixir --sname monty -S mix phx.server`."
    end
  end

  @doc """
  What the environment says about clustering, as a map — for a page that shows a
  reader why the cluster looks the way it does. Unset variables are reported as
  unset rather than as defaults, because "nobody said" and "somebody said the
  default" are different answers to a person debugging a deployment.
  """
  @spec settings() :: %{optional(String.t()) => String.t() | nil}
  def settings do
    Map.new(
      ~w(NODE_NAME NODE_COOKIE RELEASE_DISTRIBUTION RELEASE_NODE DNS_CLUSTER_QUERY PLUGIN_SCOPE PLUGIN_DISCOVERY),
      fn variable ->
        {variable, System.get_env(variable)}
      end
    )
  end

  @doc """
  The name this node's data folder carries, or `nil` when it keeps its data in the
  folder a node that runs alone keeps it in.

  Two conditions, and both are about the boot rather than about anything a page
  can change: the node was asked to join a cluster, and it is a named node that
  could. A cluster of one — a named node with no peers — is still a node with a
  name, and its data is still its own; a node that was never named cannot be
  told apart from another one on the same machine, which is exactly the case
  where sharing a folder is right.

  `config/runtime.exs` asks this once, at boot, and hands the answer to
  `Monty.Paths`.
  """
  @spec data_dir_name() :: String.t() | nil
  def data_dir_name do
    if ExTbpMonty.Cluster.enabled?() and distributed?(), do: safe_name(name())
  end

  @doc """
  A node name as a directory name.

  A node's name is `name@host`, and `@` and `:` are exactly the characters a path
  cannot carry everywhere (a Windows path cannot hold `:` at all). Everything
  outside letters, digits, the dot, the dash and the underscore becomes an
  underscore: `monty@127.0.0.1` is `monty_127.0.0.1`, which is still the node's
  name to a reader and is one path segment everywhere.
  """
  @spec safe_name(node() | String.t()) :: String.t()
  def safe_name(node_name) do
    node_name
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
  end

  @doc """
  The node's address as another node names it — `node1@10.0.0.7` — or `nil` for a
  VM that was never given a name.

  Two spellings of one node, for two readers. This one is what a person copies:
  `MONTY_SEEDS` is a list of these, and `--name`/`--sname` take one. The other is
  `safe_name/1`, which is what its folder is called — a path, not something to
  paste onto another machine.

  The host part is whatever the node was started with: an IP (`--name node1@…`),
  a short name (`--sname node1` becomes `node1@<this machine's hostname>`) or a
  fully qualified one. Showing the node's own name rather than guessing from the
  network is deliberate: it is the identical string its peers have to be told.
  """
  @spec address(node() | String.t() | nil) :: String.t() | nil
  def address(nil), do: nil

  def address(node_name) do
    case to_string(node_name) do
      "nonode@nohost" -> nil
      address -> address
    end
  end

  @doc """
  The address a node answers HTTP on, as a browser can open it — `nil` when the
  name it was given has no host to build one from.

  A node name is not a URL, and a page that lists what is running on a peer needs
  one: "run it on node2" is not something a reader can click. The port is the one
  the endpoint was configured with; the host is the host part of the node's own
  name, because that is the address its peers reached it at — `node1@127.0.0.1`
  answers on `127.0.0.1`, and a node named on a private network answers on that
  network's address.

  Takes the name rather than reading this VM's, so the rule can be stated for a
  node this one is not.
  """
  @spec web_url(node() | String.t()) :: String.t() | nil
  def web_url(node_name \\ name()) do
    with host when is_binary(host) <- host_of(node_name),
         port when is_integer(port) <- http_port() do
      "http://#{host}:#{port}"
    else
      _no_address -> nil
    end
  end

  @doc """
  Which cookie this node shares with its peers, said as a sentence and never as
  the cookie itself.

  The cookie is the cluster's password: two nodes that do not share one are two
  clusters that believe they are one, and silently so — the blueprint this design
  came from records exactly that failure. A page that *printed* the cookie would
  hand it to anybody who can open a settings screen, so what is said here is where
  it came from, which is the part a reader can act on.

  `MONTY_CLUSTER_SECRET` is the name a `mix` run reads, and `MONTY_COOKIE` is the
  same thing under the name the first launcher gave it; a release reads
  `RELEASE_COOKIE`, which `rel/env.sh.eex` fills from `NODE_COOKIE` when that is
  set. Without any of them, every VM of one user shares `~/.erlang.cookie`, which
  is why several nodes on one machine need to agree on nothing.
  """
  @spec cookie_source() :: String.t()
  def cookie_source do
    cond do
      not distributed?() ->
        "this node is not a named node, so it shares no cookie"

      System.get_env("MONTY_CLUSTER_SECRET") not in [nil, ""] ->
        "set by MONTY_CLUSTER_SECRET, the same on every node that is meant to join"

      System.get_env("MONTY_COOKIE") not in [nil, ""] ->
        "set by MONTY_COOKIE, the same on every node that is meant to join"

      true ->
        "the ~/.erlang.cookie of the user that started it"
    end
  end

  # The host part of a node name, which is the address a peer dialled. A node
  # that was never given a name is `:nonode@nohost`, and `nohost` is not an
  # address — a short name (`:monty`, no `@`) carries none either.
  defp host_of(node_name) do
    with name when name != "nonode@nohost" <- to_string(node_name),
         [_short, host] when host != "" <- String.split(name, "@") do
      host
    else
      _no_host -> nil
    end
  end

  # The port the endpoint was configured with. Read from the config rather than
  # asked of the running endpoint, so it answers on a node that is not this one.
  defp http_port do
    :ex_tbp_monty
    |> Application.get_env(ExTbpMontyWeb.Endpoint, [])
    |> Keyword.get(:http, [])
    |> Keyword.get(:port)
  end
end
