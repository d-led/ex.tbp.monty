defmodule ExTbpMonty.Repo.Migrations.AddLogPathToStudioRuns do
  use Ecto.Migration

  # Where a run's rendered log lives on disk. Stored rather than derived so a
  # run keeps pointing at its own file even if the artifacts root moves.
  def change do
    alter table(:studio_runs) do
      add :log_path, :string
    end
  end
end
