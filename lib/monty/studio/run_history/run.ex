defmodule Monty.Studio.RunHistory.Run do
  @moduledoc """
  One run, as the database remembers it.

  What is stored is what a person would want back: which experiment, with which
  config and which inputs, when it ran, how it ended, what it reported step by
  step. The trained model and any other artifact stay on the filesystem, named
  by the experiment's own paths — deleting the row deletes the record, not the
  model, which is the honest split between metadata and files.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(queued running finished stopped failed)

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "studio_runs" do
    field :experiment, :string
    field :episode, :integer, default: 0
    field :source, :string, default: "monty"
    field :status, :string, default: "queued"
    field :steps, :integer, default: 0
    # What a list draws, counted from `log` when it is written and never
    # castable from outside: they are counts of another column, not inputs.
    field :steps_done, :integer, default: 0
    field :episodes_done, :integer, default: 0
    field :seed, :integer
    field :config, :map, default: %{}
    field :inputs, :map, default: %{}
    field :summary, :map, default: %{}
    field :log, Monty.Studio.RunHistory.Json, default: []
    field :timeline, Monty.Studio.RunHistory.Json, default: []
    field :log_path, :string
    # Which node's run this is, in the spelling that decided the node's folder
    # (`Monty.Paths.data_dir_name/0`, `ExTbpMonty.Node.safe_name/1`), `nil` on a
    # node that runs alone. A page translates it to the name peers dial —
    # `node1@10.0.0.7` — because that is the string a person reads and copies.
    field :node, :string
    # Where the run was asked for, when that is not where it runs: `node` is the
    # node that has it (a claim moves it), and this one never moves. Same spelling
    # as `node`, `nil` on a node that runs alone.
    field :started_on, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :duration_us, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "The statuses a run can be in."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "A changeset for a run about to start."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(run, attributes) do
    run
    |> cast(attributes, [
      :experiment,
      :episode,
      :source,
      :status,
      :steps,
      :seed,
      :config,
      :inputs,
      :summary,
      :log,
      :timeline,
      :log_path,
      :node,
      :started_on,
      :started_at,
      :finished_at,
      :duration_us
    ])
    |> validate_required([:experiment, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:steps, greater_than_or_equal_to: 0)
  end
end
