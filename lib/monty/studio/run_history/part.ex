defmodule Monty.Studio.RunHistory.Part do
  @moduledoc """
  One part of a divided run: how much of the experiment it is, where it ran, and
  how far it got.

  The run's own row is the record of the experiment; this is the record of the
  division. A run of four parts has one row here per part, and the question they
  answer is the one the run's row cannot: *where* each part was performed. Today
  every part of a run is performed by the node that merges them, and that is what
  a row will say until a part may be handed to a peer —
  `ExTbpMonty.Cluster.Placement` is what would decide that.

  `part` is zero-based, as `Monty.Studio.Partition` numbers its parts, so `part`
  plus one is the number a log line prints and a person counts.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Monty.Studio.RunHistory.Run

  @statuses ~w(queued running finished failed)

  @typedoc """
  One part's row: which part of how many, what state it is in, and the node that
  has it — `nil` until a node takes it, which is the only column that is not a
  fact the moment the row is written.
  """
  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          run_id: Ecto.UUID.t() | nil,
          part: non_neg_integer() | nil,
          of: pos_integer() | nil,
          node: String.t() | nil,
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
  What may be written about a part.

  `node` is set when a node takes the part rather than when the run is asked for,
  which is the same order the run itself follows, and `status` is the one column
  every write names.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(part \\ %__MODULE__{}, attributes) do
    part
    |> cast(attributes, [:run_id, :part, :of, :node, :status, :steps, :started_at, :finished_at])
    |> validate_required([:run_id, :part, :of, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:steps, greater_than_or_equal_to: 0)
  end
end
