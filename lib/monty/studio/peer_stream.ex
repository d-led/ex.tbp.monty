defmodule Monty.Studio.PeerStream do
  @moduledoc """
  The steps of a part that another node has.

  A part's steps are in the memory of the node stepping it — `RunStream` on that
  node — and the only place that node is written is the part's claim row
  (`studio_run_parts.node`, by `RunHistory.claim_part/3`). So this module answers
  the two questions a page on the owner needs: which parts are in a peer's hands,
  and how much of one a peer has taken.

  What comes back is the **entries**, never `read_from/2`'s moments: a page that
  never had the pictures inline cannot show them, and a peer's moments are eleven
  kilobytes a step (§48 measured 145 MB for 13 000 steps). A part's pictures
  therefore arrive the way they always did — with the part's file, when it ends.

  A node that is gone, silent or not in this cluster answers nothing, and nothing
  is a page falling back on the record, which is what it showed before any of this
  existed. That is why every read is bounded by `@timeout`: a silent peer must not
  hold a page's poll.
  """

  alias ExTbpMonty.Cluster.Nodes

  alias Monty.Studio.{RunHistory, RunStream}

  # Shorter than a page's own poll (500 ms), so a peer that has gone quiet costs a
  # poll less than the poll itself.
  @timeout 500

  @typedoc """
  One part in a peer's hands: the node that has it, and how many steps it has
  taken there.
  """
  @type claim :: %{node: String.t(), steps: non_neg_integer()}

  @doc """
  The parts a peer is stepping, by the number the division gave them.

  `%{}` for a run of one part, and for a run whose parts this node has all of: a
  part in this node's own hands is read here, not asked over the network.
  """
  @spec claimed(binary()) :: %{optional(non_neg_integer()) => claim()}
  def claimed(run_id) do
    me = ExTbpMonty.Node.safe_name(node())

    run_id
    |> RunHistory.claimed_parts()
    |> Enum.reject(&(&1.node in [nil, me]))
    |> Map.new(&{&1.part, %{node: &1.node, steps: &1.steps || 0}})
  end

  @doc """
  The entries a peer holds for `stream`, after the first `from`.

  A negative `from` is the whole part — no part has a step below nought — which is
  what a page that has just opened asks for.
  """
  @spec entries(String.t(), binary(), integer()) :: [map()]
  def entries(holder, stream, from) do
    case node_holding(holder) do
      nil -> []
      node -> read(node, stream, from)
    end
  end

  @doc """
  Whether `holder` is a node this cluster has, alive — the question `entries/3`
  asks before it reaches for one.
  """
  @spec holding?(String.t()) :: boolean()
  def holding?(holder), do: node_holding(holder) != nil

  defp node_holding(holder) do
    Enum.find_value(Nodes.snapshot(), fn entry ->
      entry.alive and entry.name == holder and entry.node
    end)
  end

  defp read(node, stream, from) do
    case :rpc.call(node, RunStream, :entries_from, [stream, from], @timeout) do
      entries when is_list(entries) -> entries
      _no_answer -> []
    end
  end
end
