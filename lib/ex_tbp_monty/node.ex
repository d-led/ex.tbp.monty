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
end
