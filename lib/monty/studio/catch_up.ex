defmodule Monty.Studio.CatchUp do
  @moduledoc """
  The steps a page missed, from every stream the run is writing.

  A divided run does not write one stream: each part keeps its own
  (`Monty.Studio.Jobs.Run` divides an experiment, and a part's steps go to the
  stream the plan names), and a part may be stepped on another node. So "what did
  this page miss" is not one read — it is the run's own stream, every part's stream
  held here, and every peer's part read from the node that has it
  (`Monty.Studio.PeerStream`).

  The cursors are what make that affordable: one count per stream, kept by the
  caller between polls, so each read is the tail and not the transcript. A stream
  that has not moved is not read at all, and a peer is not asked unless its claim
  row says it has taken more steps than the page has drawn — which is why the
  claim's `steps` matters here and a peer costs no message while it is idle.

  Entries, never moments: see `Monty.Studio.PeerStream` for why a page cannot use
  a peer's pictures, and `RunStream.entries_from/2` for why this port does not
  read them either.
  """

  alias Monty.Studio.{Parts, PeerStream, RunStream}

  @typedoc "How many steps of each stream the caller has drawn, by stream id."
  @type cursors :: %{optional(binary()) => non_neg_integer()}

  @doc """
  The entries this page has not drawn yet, oldest step first, and the cursors that
  say so.

  `:read` answers `(holder, stream, from) -> entries` for a part in a peer's hands
  and `:claimed` answers the claim rows, both so a test can answer without two
  VMs; the defaults are the cluster's.
  """
  @spec entries(map(), cursors(), keyword()) :: {[map()], cursors()}
  def entries(record, cursors \\ %{}, options \\ [])

  def entries(record, cursors, options) do
    read = Keyword.get(options, :read, &PeerStream.entries/3)
    claimed = Keyword.get_lazy(options, :claimed, fn -> PeerStream.claimed(record.id) end)

    {batches, cursors} =
      Enum.reduce([{record.id, nil} | part_streams(record)], {[], cursors}, fn {stream, part},
                                                                               acc ->
        taken(acc, stream, part, claimed, read)
      end)

    {batches |> Enum.concat() |> Enum.sort_by(&{&1["episode"], &1["step"]}), cursors}
  end

  @doc """
  How many steps of the run this node can count without asking anybody: its own
  streams, and what the claim rows say of the parts a peer has.

  The question a page asks before it reads anything — a page that is not behind by
  more than a message or two is a page whose mailbox is in flight, and reading to
  learn that is the page paying for the run's history.
  """
  @spec held(map(), keyword()) :: non_neg_integer()
  def held(record, options \\ []) do
    claimed = Keyword.get_lazy(options, :claimed, fn -> PeerStream.claimed(record.id) end)

    [{record.id, nil} | part_streams(record)]
    |> Enum.map(fn {stream, part} -> held_of(stream, part, claimed) end)
    # `Enum.sum/1` is typed `[number()] -> number()`, so a count added with it
    # widens to `float()` and the spec above stops being true.
    |> Enum.reduce(0, &+/2)
  end

  # A stream the caller has already drawn up to `from`: its tail, and the count
  # that says how far the cursor may go. A peer is asked nothing while its claim
  # says it has taken no more than the page has drawn.
  defp taken({batches, cursors}, stream, part, claimed, read) do
    from = Map.get(cursors, stream, 0)
    {entries, held} = read_stream(stream, part, claimed, from, read)

    {[entries | batches], Map.put(cursors, stream, max(held, from + length(entries)))}
  end

  defp read_stream(stream, part, claimed, from, read) do
    case RunStream.count(stream) do
      count when count > from ->
        {RunStream.entries_from(stream, from - 1), count}

      _nothing_here ->
        case Map.get(claimed, part) do
          %{steps: steps, node: holder} when steps > from ->
            {read.(holder, stream, from - 1), steps}

          _no_part_of_ours ->
            {[], from}
        end
    end
  end

  defp held_of(stream, part, claimed) do
    case RunStream.count(stream) do
      0 ->
        case Map.get(claimed, part) do
          %{steps: steps} -> steps
          _no_part_of_ours -> 0
        end

      count ->
        count
    end
  end

  # The plan's parts, numbered as the claims are: a run of the whole experiment has
  # none, and its own stream is the whole of the transcript.
  defp part_streams(record), do: Enum.map(Parts.parts_of(record), &{&1["stream"], &1["index"]})
end
