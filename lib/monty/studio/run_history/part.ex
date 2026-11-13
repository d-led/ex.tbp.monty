defmodule Monty.Studio.RunHistory.Part do
  @moduledoc """
  One part of a divided run: how much of the experiment it is, where it ran, and
  how far it got.

  The run's own row is the record of the experiment; this is the record of the
  division. A run of four parts has one row here per part, and the question they
  answer is the one the run's row cannot: *where* each part is performed, *who*
  has it now and how far it got. A part is performed by any node that shares the
  run's files, so the row is also the place the cluster agrees on ownership: the
  claim and its lease (`Monty.Studio.Claim`) are what a second node is refused by
  and what makes a part whose holder went silent recoverable.

  `part` is zero-based, as `Monty.Studio.Partition` numbers its parts, so `part`
  plus one is the number a log line prints and a person counts.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Monty.Studio.RunHistory.Run

  # `skipped` is a part the run never got to — a wave that failed before it, or a
  # run stopped between waves. Without it a settled run would leave rows saying
  # `queued` for ever, which is the same lie an abandoned run's row used to tell.
  #
  # `stopped` is the part the stop arrived in: it did some of its work and was
  # cut short, which is neither finished nor failed, and the run's own row has
  # said `stopped` about the same moment since the stop existed.
  @statuses ~w(queued running finished failed stopped skipped)

  @typedoc """
  One part's row: which part of how many, what state it is in, and the node that
  has it — `nil` until a node takes it, which is the only column that is not a
  fact the moment the row is written.

  `claim` is the token of the claim the node holds and `claimed_until` is when it
  lapses (`Monty.Studio.Claim`): together they are what a write about the part is
  checked against, so a node that lost its part cannot overwrite the node that has
  it now.
  """
  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          run_id: Ecto.UUID.t() | nil,
          part: non_neg_integer() | nil,
          of: pos_integer() | nil,
          node: String.t() | nil,
          claim: String.t() | nil,
          claimed_until: DateTime.t() | nil,
          status: String.t(),
          steps: non_neg_integer(),
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "studio_run_parts" do
    field :part, :integer
    field :of, :integer
    field :node, :string
    field :claim, :string
    field :claimed_until, :utc_datetime_usec
    field :status, :string, default: "queued"
    field :steps, :integer, default: 0
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    belongs_to :run, Run, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The states a part can be in: asked for, in hand, done, or stopped early."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc """
  Whether a part in this state has ended — however it ended.

  The question a progress line asks ("2 of 4 parts done") is how many parts
  nothing more will happen to, not how many succeeded: a part that failed, was
  stopped with the run, or was never reached has ended too.
  """
  @spec ended?(String.t()) :: boolean()
  def ended?(status), do: status in ~w(finished failed stopped skipped)

  @doc """
  What may be written about a part.

  `node` is set when a node takes the part rather than when the run is asked for,
  which is the same order the run itself follows, and `status` is the one column
  every write names. `claim` and `claimed_until` travel with the node that sets
  them: they are what the cluster agrees on about who has the part
  (`Monty.Studio.Claim`), and they are written by `Monty.Studio.RunHistory`
  directly rather than through a changeset, because every one of those writes is a
  condition on the row as much as a change to it.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(part \\ %__MODULE__{}, attributes) do
    part
    |> cast(
      attributes,
      [
        :run_id,
        :part,
        :of,
        :node,
        :claim,
        :claimed_until,
        :status,
        :steps,
        :started_at,
        :finished_at
      ]
    )
    |> validate_required([:run_id, :part, :of, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:steps, greater_than_or_equal_to: 0)
  end
end
