defmodule ExTbpMonty.Cluster.Placement do
  @moduledoc """
  Which node may perform a run, decided from the tags the nodes declare.

  A heterogeneous cluster is one where a node is not interchangeable with its
  peers: one has a GPU, one has the Python a plugin needs, one is a laptop that
  should not be handed an eighty-hour run. Tags say so
  (`ExTbpMonty.Cluster.Capabilities`); a run says what it needs; this decides
  whether the node holding the job may take it.

  ## Three answers

    * the local node offers everything the run needs — it performs the run,
      exactly as a node that runs alone performs it;
    * it does not, but a live peer does — the job is put back (`{:snooze, n}`)
      and waits for that peer's queue to take it;
    * nobody offers them — the local node performs it anyway. A run is never
      held hostage by a tag nobody declared: a cluster of untagged peers behaves
      as one untagged machine, and a lone node cannot tell this answer from
      doing the work itself.

  That last rule is what keeps the non-networked studio untouched. On one node
  the list of nodes is that node, it offers `monty`, and the decision is always
  the first answer.

  ## What a run needs

  `monty`, because every node of this application is one, plus whatever the run
  asked for in its inputs under `capabilities` — that is how a run is pinned to
  the machine that has what it takes:

      inputs: %{"capabilities" => ["gpu"]}

  A need is a *filter*, not a request: it says which nodes are allowed to
  perform the run, and never that a particular one must. Two nodes that both
  offer a tag are two places the run may go, and whatever queue gets there first
  takes it.
  """

  alias ExTbpMonty.Cluster.Capabilities

  # Every node of this application can run a run of it. A node that says
  # otherwise is not this application.
  @always "monty"

  # The wait `turn/2` asks for; `snooze_seconds/0` says why it is this number.
  @snooze_seconds 15

  @doc """
  How long a job waits before asking again whether a node that can take it is
  still around.

  Short enough that a node joining is noticed while a person is still watching
  the queue, long enough that an idle cluster does not poll a database twice a
  second because of a job that some other node has yet to pick up.
  """
  @spec snooze_seconds() :: pos_integer()
  def snooze_seconds, do: @snooze_seconds

  @doc """
  The tags a run needs: `monty`, the world it steps, and whatever its inputs
  asked for — in one spelling, without repeats.

  The world is a need because it is the one thing about a run that this port
  cannot do on a machine that lacks it: a run recorded as MuJoCo must not be
  handed to the node that cannot step MuJoCo, and `world:mujoco` is the tag that
  says which node can. A run that names no world needs nothing beyond `monty`,
  which is every run asked for from the studio's own page — a person who has not
  heard of tags should not need an opinion about them.
  """
  @spec needs(map() | nil) :: [String.t()]
  def needs(inputs) do
    inputs = inputs || %{}

    [@always | asked(inputs) ++ world(inputs)]
    |> Enum.map(&Capabilities.normalise/1)
    |> Enum.uniq()
  end

  @doc """
  The nodes a run needing `needs` could be performed on: alive ones that offer
  all of it, in the order the list gave them.

  A node that did not answer its poll is not a place a run can go, however well
  its tags fit: it is a node whose tags are the last thing this cluster heard of
  it.
  """
  @spec candidates([map()], [String.t()]) :: [map()]
  def candidates(entries, needs) do
    Enum.filter(entries, &(&1.alive && offers?(&1, needs)))
  end

  @doc """
  What the node holding the job should do with it: perform it, or wait.

  See the module's three answers. The local node is the entry that says `self`,
  not the one whose name matches, because an entry's name is the safe form of a
  node name and this decision is about the node itself.
  """
  @spec turn([map()], [String.t()]) :: :here | {:wait, pos_integer()}
  def turn(entries, needs) do
    live = Enum.filter(entries, & &1.alive)

    cond do
      Enum.any?(live, &(&1.self && offers?(&1, needs))) -> :here
      Enum.any?(live, &offers?(&1, needs)) -> {:wait, @snooze_seconds}
      true -> :here
    end
  end

  defp offers?(entry, needs) do
    tags = Capabilities.of_entry(entry)
    Enum.all?(needs, &Capabilities.offers?(tags, &1))
  end

  defp asked(inputs) do
    inputs
    |> Map.get("capabilities", [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  # A record keeps its world as the word the setup used (`"mujoco"`,
  # `"synthetic"`), and the tags that name a world are `world:<that word>`.
  # `synthetic` is exempt because it is this port's own scene, in every build of
  # it: no node can be without it, so a tag saying so would be a need nobody has.
  defp world(%{"world" => world}) when is_binary(world) and world != "synthetic",
    do: ["world:" <> world]

  defp world(_inputs), do: []
end
