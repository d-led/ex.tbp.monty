defmodule Monty.Studio.Claim do
  @moduledoc """
  A node's claim on one part of a run: who has it, until when, and the token that
  fences what the holder writes.

  A part is not a task in a pool. It owns a stretch of an experiment, it writes
  the file its run's transcript is made of, and any node of the cluster may be
  asked to perform it — so "which node has part 2 of this run" is a fact the
  cluster needs, and it needs it to survive a node that stops answering.

  Two things follow, and both are this module's reason to exist:

    * **ownership is recorded** — `Monty.Studio.RunHistory.claim_part/4` writes a
      claim into the part's row before the part is performed: the node, and the
      moment the claim lapses if nobody renews it;
    * **a write is fenced** — the token is the claim's identity. A node that lost
      its part (a peer believed dead that came back, a worker whose claim lapsed
      and was given to somebody else) still holds a token, and every write it
      makes with that token is refused by
      `Monty.Studio.RunHistory.release_part/3`. Nothing it writes after losing the
      part can overwrite the node that has the part now.

  ## Why a lease rather than a lock

  A lock held by a node that died is never released, and a part of a run is
  minutes to hours of work: the cluster cannot wait for a person to unlock it. A
  lease says "mine until T, and I will say so again before then" — so a node that
  dies silently loses its parts when T passes, and a node that is alive and
  working keeps them without anyone else having to ask.
  """

  @ttl_seconds 600

  @typedoc """
  One claim: the part it is on, the node holding it, and the moment it lapses.

  `token` is what fences a write; it is generated per claim, so two claims of the
  same part — the second after the first lapsed — are two different tokens and
  cannot be mistaken for one another.
  """
  @type t :: %__MODULE__{
          run_id: Ecto.UUID.t(),
          part: non_neg_integer(),
          node: String.t(),
          token: String.t(),
          until: DateTime.t()
        }

  @enforce_keys [:run_id, :part, :node, :token, :until]
  defstruct [:run_id, :part, :node, :token, :until]

  @doc """
  How long a claim stands without a word from its holder.

  Ten minutes of silence is a dead worker rather than a slow one: a part that is
  working renews its claim as it steps (`Monty.Studio.Jobs.Run`), so the only way
  to be silent for this long is to have stopped.
  """
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  @doc "A fresh claim on `part` of `run_id`, held by `node` from `now`."
  @spec new(Ecto.UUID.t(), non_neg_integer(), String.t(), DateTime.t(), pos_integer()) :: t()
  def new(run_id, part, node, now \\ DateTime.utc_now(), ttl \\ @ttl_seconds) do
    %__MODULE__{
      run_id: run_id,
      part: part,
      node: node,
      token: Ecto.UUID.generate(),
      until: lapsing(now, ttl)
    }
  end

  @doc """
  Whether a claim has lapsed: no holder is entitled to the part after `until`.

  A claim with no `until` is one that was released — settled or abandoned — and a
  claim that was never made is `nil`; both answer `true`, because in both cases
  nobody holds the part.
  """
  @spec lapsed?(t() | nil | DateTime.t() | nil, DateTime.t()) :: boolean()
  def lapsed?(nil, _now), do: true
  def lapsed?(%__MODULE__{until: until}, now), do: lapsed?(until, now)
  def lapsed?(%DateTime{} = until, now), do: DateTime.compare(until, now) != :gt

  @doc """
  Whether `token` is the one that still owns the part — the question a write asks
  before it writes.

  Answered from the row's own columns rather than from the claim in hand: the
  claim in hand is what the writer remembers, and a writer that remembers is
  exactly the one that needs to be checked.
  """
  @spec holds?(map(), String.t() | nil, DateTime.t()) :: boolean()
  def holds?(%{claim: token, claimed_until: until}, token, now) when is_binary(token),
    do: not lapsed?(until, now)

  def holds?(_row, _token, _now), do: false

  @doc "The same claim, renewed from `now` — `until` moves, the token does not."
  @spec renew(t(), DateTime.t(), pos_integer()) :: t()
  def renew(%__MODULE__{} = claim, now \\ DateTime.utc_now(), ttl \\ @ttl_seconds) do
    %{claim | until: lapsing(now, ttl)}
  end

  defp lapsing(now, ttl), do: DateTime.add(now, ttl, :second) |> DateTime.truncate(:microsecond)
end
