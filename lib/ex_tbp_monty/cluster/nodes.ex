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

      %{node: :monty@10.0.0.7, name: "monty_10.0.0.7", address: "monty@10.0.0.7",
        self: true, version: "0.1.3", capabilities: ["gpu", "monty"],
        web: "http://10.0.0.7:4000", artifacts: "/mnt/runs", alive: true}

  Two spellings of the name travel because two readers ask for different ones.
  `address` is the node's own name — `monty@10.0.0.7`, the string a person copies
  into `MONTY_SEEDS` and the one `--name` takes — and is `nil` for a VM that was
  never named. `name` is the same name made safe for a path
  (`ExTbpMonty.Node.safe_name/1`), which is what its data folder is called; a
  page shows the address, and a reader who sees a folder on disk is looking at
  the same node under the spelling a path allows.

  `capabilities` and `web` travel with the version because all three come from the
  same `:rpc` (`identity/0`) and all three are answers to "what is that node": a
  heterogeneous cluster is one where the tags decide which node a run may go to,
  and a node whose tags cost a second round trip would be a list that is half up
  to date. `ExTbpMonty.Cluster.Capabilities` is the vocabulary; `web` is there so
  a page can link to a peer's run rather than only name it, because a node name is
  not a URL (`ExTbpMonty.Node.web_url/1`).

  An entry may also be a node that does not run this application at all. A plugin
  host is one — it offers learning modules, experiments or motor policies to the
  cluster without being the studio — and it answers the same three questions from
  what its own registry holds (`MontyPlugin.Registry.identity/0`), so its tags are
  `plugin` and one `plugin:<kind>` per kind it offers. Nothing here asks what code
  a peer loaded: the tags say what it provides, and a peer that answers neither
  question is the one entry that is not alive.
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

  # The last list, where a reader can take it without asking anybody. Reads are
  # free and writes happen on a change only — at worst once per poll, and never
  # when nothing moved.
  @snapshot {__MODULE__, :snapshot}

  @doc """
  The cluster as a list, this node first.

  Answered from the last poll rather than by asking the poller: the poller may be
  in the middle of an `:rpc` to a peer that is slow to answer, and a page that
  called it would wait behind that peer — a `GenServer.call` with a peer per node
  and a timeout each is a page that can time out, which is a crash for reading a
  list.

  A node that runs alone — no poller at all — still answers, by building the list
  a cluster of one has from this node. A poller that has not finished its first
  poll answers the same way: slower than it will be, and never wrong.
  """
  @spec snapshot() :: [map()]
  def snapshot do
    case :persistent_term.get(@snapshot, :none) do
      :none -> of(Cluster.nodes())
      entries -> entries
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
        address: Node.address(name),
        self: name == node(),
        version: version,
        capabilities: capabilities_of(answer),
        web: web_of(answer),
        artifacts: artifacts_of(answer),
        plugins: plugins_of(answer),
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
  What this node tells a peer that asks: its node name, the build it runs, what
  it can do, where it answers, and where it writes a run's files.

  The last one is not a detail about this node's disk: a part of a run is a log, a
  handful of pictures and a statistics file, and the node that owns the run reads
  them from its own directory. A part may therefore only be performed where the
  same directory is written — `shares_run_files?/2` is that question — and a
  deployment answers it by pointing `MONTY_ARTIFACTS_DIR` at one place
  (`Monty.Paths.artifacts/0`).

  Called by `:rpc` from another node's poller, so it must stay cheap and must not
  touch anything a page owns.
  """
  @spec identity() :: %{
          node: node(),
          version: String.t(),
          capabilities: [String.t()],
          web: String.t() | nil,
          artifacts: String.t()
        }
  def identity do
    %{
      node: node(),
      version: version(),
      capabilities: Capabilities.declared(),
      web: Node.web_url(),
      artifacts: Monty.Paths.artifacts()
    }
  end

  @doc """
  Whether two nodes write a run's files where the other can read them.

  Files do not travel: a part's log, its pictures and the statistics it merged
  from are written by whoever performed it and read by the node that owns the run.
  Two nodes answer `true` here only when both say they write the same directory —
  a mount, a share, or one machine's own folder reached by the same path. A node
  that did not say (an older build, or an answer with no `:artifacts`) is not known
  to share anything, and `false` is the answer: "probably the same path" is not a
  fact to hand a run's output to.
  """
  @spec shares_run_files?(map(), map()) :: boolean()
  def shares_run_files?(%{artifacts: where}, %{artifacts: where}) when is_binary(where), do: true
  def shares_run_files?(_left, _right), do: false

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # The first list is ready before the first page asks for it: a page opened on
    # a node that just started would otherwise wait for a poll it did not start.
    state = poll()
    remember(state)
    schedule()

    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    schedule()
    entries = poll()

    # Said only when it changed: a page that re-rendered every three seconds for
    # nothing would be a page that never stops working.
    if entries != state do
      remember(entries)
      announce(entries)
    end

    {:noreply, entries}
  end

  defp remember(entries), do: :persistent_term.put(@snapshot, entries)

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

  # The version on a node that is not there is `nil`, which is what `alive:
  # false` means.
  #
  # A peer that does not run this application cannot answer `identity/0`, and a
  # plugin host is exactly that peer: it is in the cluster on purpose, and the
  # module below is the package that answers the same three questions from what
  # it has registered. `:rpc` needs no compile-time dependency, so the module is
  # named as an atom and asked rather than linked — a studio node must not have
  # to depend on the plugin package in order to see one.
  @plugin_identity Module.concat(["MontyPlugin", "Registry"])

  defp ask(name) do
    :rpc.call(name, __MODULE__, :identity, [], @probe_ms)
    |> answer_of(fn -> :rpc.call(name, @plugin_identity, :identity, [], @probe_ms) end)
  end

  @doc """
  The answer one peer gave, or the one its plugin registry gave in its place.

  Public because the fallback is the interesting half and a test cannot make this
  VM stop being a studio node: given what the first question returned, this is
  what the poller does next. `nil` is a node that answered neither question.
  """
  @spec answer_of(term(), (-> term())) :: map() | nil
  def answer_of(%{} = answer, _ask_plugin_host), do: answer

  def answer_of(_not_a_studio_node, ask_plugin_host) do
    case ask_plugin_host.() do
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

  # Where it answers, when it said. A peer that did not say, or that has no name
  # to put in a URL, is a node a page can only name.
  defp web_of(%{web: web}) when is_binary(web), do: web
  defp web_of(_answer), do: nil

  # Where it writes a run's files, when it said. `nil` is a peer older than this
  # question, and `shares_run_files?/2` reads it as "not known to share".
  defp artifacts_of(%{artifacts: where}) when is_binary(where), do: where
  defp artifacts_of(_answer), do: nil

  # What a plugin host offers, in the words its own registry uses
  # (`MontyPlugin.Registry.offered/0`: one `%{"kind" =>, "name" =>}` per plugin).
  #
  # Free, and that is the point of it being here: the list arrives with the answer
  # the poller already asks for, so a page can say *which* plugins a machine
  # brings without a single extra message. Two of the loop rules hold it up — the
  # host answers from its own `:pg` rather than asking anybody (so no fan-out), and
  # the poller announces only when the entries changed (so no echo): see
  # `docs/plugins.md`.
  #
  # A studio node has no `plugins` key and offers none, which is the same empty
  # list a build too old to say would give.
  defp plugins_of(%{plugins: plugins}) when is_list(plugins) do
    for %{"kind" => kind, "name" => name} <- plugins, is_binary(kind), is_binary(name) do
      %{"kind" => kind, "name" => name}
    end
  end

  defp plugins_of(_answer), do: []

  defp version do
    case Application.spec(:ex_tbp_monty, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end
end
