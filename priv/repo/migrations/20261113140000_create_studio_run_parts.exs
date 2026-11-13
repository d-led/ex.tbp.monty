defmodule ExTbpMonty.Repo.Migrations.CreateStudioRunParts do
  use Ecto.Migration

  # One row per part of a run that was divided (`Monty.Studio.Partition`).
  #
  # A parted run is one record with one transcript, and that is what a reader of
  # the run wants. What the record cannot say is *where* a part was performed:
  # the parts are processes inside one job today, and the moment one of them may
  # be performed by a peer, "which node ran part 3" stops being answerable from
  # the run's own row — the row names one node, and that node is the one that
  # merges the parts, not necessarily the one that ran them.
  #
  # `node` is null until a node takes the part, which is the same two-step the run
  # itself takes: asked for (`started_on`), then claimed (`node`). It is written in
  # the spelling that decided the node's folder, like `studio_runs.node`, and a
  # page translates it to the name peers dial.
  def change do
    create table(:studio_run_parts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, :binary_id, null: false
      add :part, :integer, null: false
      add :of, :integer, null: false
      add :node, :string
      add :status, :string, null: false
      add :steps, :integer, default: 0
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # A part of a run is one row: two workers of one run writing part 2 twice is a
    # mistake the database refuses rather than a page that shows it twice.
    create unique_index(:studio_run_parts, [:run_id, :part])
  end
end
