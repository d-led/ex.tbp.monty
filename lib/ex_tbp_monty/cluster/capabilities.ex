defmodule ExTbpMonty.Cluster.Capabilities do
  @moduledoc """
  What a node can do, as tags — the question a cluster of unlike machines has to
  answer before anything is put on them.

  A cluster of identical nodes needs no vocabulary: every node can do everything,
  and "which node" is only "which one is free". A heterogeneous one is the case
  this exists for. One machine steps MuJoCo; another has the GPU; a third brings
  modules this checkout does not have. A run that needs the GPU is not a run whose
  placement is a matter of load, and a scheduler cannot ask a question about it
  unless the answer is a value two nodes can compare — a tag.

  ## The vocabulary

  A tag is a short lowercase string, no spaces: `"monty"`, `"gpu"`,
  `"world:mujoco"`, `"plugin:learning_module"`. A colon groups a family, which
  keeps the namespace open for tags this checkout has never heard of: a node that
  does not recognise a tag does not have to, it only has to be able to compare it.

  Strings rather than atoms, deliberately. A tag arrives from an environment
  variable and from other people's nodes, and `String.to_atom/1` on either is a
  table that only grows.

  ## Where a node's tags come from

  * `"monty"` — always, because every node in this cluster runs this
    application's modules. It is what a run with no special needs asks for.
  * `MONTY_CAPABILITIES`, comma-separated, so a deployment says what its machine
    has without a code change. `process-compose.yaml` passes it through, and
    `elixir --name … -S mix phx.server` reads it on every platform the same way.
  * A node that brings plugins declares the tags of the plugins it brings, in the
    same list. What a plugin contributes is that work's own business; that it is
    advertised here is the seam.
  """

  # What every node of this cluster can do.
  @always "monty"

  # The prefix a node uses to say it *provides* something rather than *has* a
  # machine that can do it: `plugin`, `plugin:learning_module`,
  # `plugin:experiment`. See `plugin?/1`.
  @plugin "plugin"

  @variable "MONTY_CAPABILITIES"

  @doc """
  The tags this node advertises, sorted and without duplicates — what a peer is
  told when it asks.
  """
  @spec declared() :: [String.t()]
  def declared do
    Enum.sort(Enum.uniq([@always | from_environment()]))
  end

  @doc """
  The tags `MONTY_CAPABILITIES` adds.

  Reported on its own because it is the part a deployment changes, and a settings
  page that conflates it with the built-in tag cannot say what came from where.
  """
  @spec from_environment() :: [String.t()]
  def from_environment do
    @variable
    |> System.get_env("")
    |> String.split(",", trim: true)
    |> Enum.map(&normalise/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @doc """
  A tag in the one spelling every comparison uses.

  `WORLD:MUJOCO`, `world:mujoco ` and `"World:Mujoco"` are one tag: a value that
  arrives from an environment variable and a value that arrives from a peer are
  written by different people, and a comparison that is case-sensitive would
  silently never match.
  """
  @spec normalise(String.t() | atom()) :: String.t()
  def normalise(tag) do
    tag
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/u, "-")
  end

  @doc """
  Whether a node's tags answer a question asked in any spelling.
  """
  @spec offers?(Enumerable.t(), String.t() | atom()) :: boolean()
  def offers?(tags, tag) do
    wanted = normalise(tag)
    Enum.any?(tags, &(normalise(&1) == wanted))
  end

  @doc """
  Which nodes can do what: one row per tag, the nodes that offer it by name.

  Both directions of the question matter to a reader of a heterogeneous cluster —
  "what can this node do" is the node's row, "who can do this" is this — and a
  settings page that showed only the first would make a mismatch between two
  nodes invisible.
  """
  @spec by_tag([map()]) :: [{String.t(), [String.t()]}]
  def by_tag(entries) do
    entries
    |> Enum.flat_map(fn entry ->
      Enum.map(of_entry(entry), &{normalise(&1), label(entry)})
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {tag, names} -> {tag, names |> Enum.uniq() |> Enum.sort()} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc """
  Whether an entry is a node that brings plugins.
  A node is a plugin host when it says so in the one vocabulary there is: a tag
  beginning with `plugin` — `plugin`, `plugin:learning_module`,
  `plugin:experiment` — is a claim about what the node *provides* rather than about
  the machine it runs on, which is the distinction the settings page draws when it
  groups the cluster in two.

  Kept here, beside the spelling rules, because the page and any future scheduler
  must agree about what a plugin node is, and the honest answer is "the tags say".
  """
  @spec plugin?(map()) :: boolean()
  def plugin?(entry) do
    entry |> of_entry() |> Enum.any?(&String.starts_with?(&1, @plugin))
  end

  # How a page names a node: the address a person can paste (`node1@10.0.0.7`),
  # or the folder spelling for a VM that was never named — a list that shows
  # nothing at all is worse than one that shows the name a folder has.
  defp label(entry), do: Map.get(entry, :address) || entry.name

  @doc """
  A node entry's tags, in the spelling comparisons use.

  An entry from a peer that does not advertise tags — one running a build older
  than this vocabulary — has none, and "none" is the honest answer: it can only be
  given work that needs nothing in particular.
  """
  @spec of_entry(map()) :: [String.t()]
  def of_entry(entry) do
    # `List.wrap/1`: an entry from a peer that does not advertise tags has no
    # `:capabilities` at all, and nothing is a list of no tags.
    entry
    |> Map.get(:capabilities)
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalise/1)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
