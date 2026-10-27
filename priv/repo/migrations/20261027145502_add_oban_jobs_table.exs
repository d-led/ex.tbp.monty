defmodule ExTbpMonty.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 12)

  # The jobs this table holds are runs; taking the schema away takes the runs
  # away, which is what dropping the studio_runs rows beside it does anyway.
  def down, do: Oban.Migration.down(version: 1)
end
