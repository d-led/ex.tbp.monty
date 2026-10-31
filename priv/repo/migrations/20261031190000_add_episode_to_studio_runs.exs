defmodule ExTbpMonty.Repo.Migrations.AddEpisodeToStudioRuns do
  use Ecto.Migration

  # Which episode of the epoch a run is. A run is one episode, so parallel runs
  # of one experiment differ by this and by nothing else — without it, ten rows
  # of the same experiment are indistinguishable.
  def change do
    alter table(:studio_runs) do
      add :episode, :integer, null: false, default: 0
    end

    create index(:studio_runs, [:experiment, :episode])
  end
end
