defmodule ExTbpMonty.Repo.Migrations.AddTimelineToStudioRuns do
  use Ecto.Migration

  # A run's log says what the modules reported; the timeline says what they were
  # looking at. Keeping the observations is what makes a finished run replayable
  # frame by frame without re-running it — and they are numbers, not artifacts,
  # so they belong beside the config snapshot rather than on disk.
  def change do
    alter table(:studio_runs) do
      add :timeline, {:array, :map}, null: false, default: []
    end
  end
end
