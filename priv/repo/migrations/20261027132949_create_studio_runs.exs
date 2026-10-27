defmodule ExTbpMonty.Repo.Migrations.CreateStudioRuns do
  use Ecto.Migration

  # A run is history the moment it starts, not a log line at the end: the
  # config snapshot and the inputs are the record of *what* ran, and they are
  # small. Artifacts stay on the filesystem; nothing here is the model.
  def change do
    create table(:studio_runs, primary_key: false) do
      # A run is addressed by id in a URL, so it is a UUID rather than a
      # sequence: nothing to guess, and no order implied by the id.
      add :id, :binary_id, primary_key: true
      add :experiment, :string, null: false
      add :source, :string, null: false, default: "monty"
      add :status, :string, null: false, default: "running"
      add :steps, :integer, null: false, default: 0
      add :seed, :integer
      # The composed config, as data: a snapshot that can be diffed, searched
      # and rendered without re-composing an experiment whose files may have
      # changed since.
      add :config, :map, null: false, default: %{}
      add :inputs, :map, null: false, default: %{}
      add :summary, :map, null: false, default: %{}
      add :log, {:array, :map}, null: false, default: []
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :duration_us, :bigint, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:studio_runs, [:experiment])
    create index(:studio_runs, [:inserted_at])
  end
end
