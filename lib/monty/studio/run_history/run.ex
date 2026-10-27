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

  @statuses ~w(running finished failed)

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "studio_runs" do
    field :experiment, :string
    field :source, :string, default: "monty"
    field :status, :string, default: "running"
    field :steps, :integer, default: 0
    field :seed, :integer
    field :config, :map, default: %{}
    field :inputs, :map, default: %{}
    field :summary, :map, default: %{}
    field :log, {:array, :map}, default: []
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
      :source,
      :status,
      :steps,
      :seed,
      :config,
      :inputs,
      :summary,
      :log,
      :started_at,
      :finished_at,
      :duration_us
    ])
    |> validate_required([:experiment, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:steps, greater_than_or_equal_to: 0)
  end
end
