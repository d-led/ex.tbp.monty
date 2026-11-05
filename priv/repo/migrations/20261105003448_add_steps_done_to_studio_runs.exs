defmodule ExTbpMonty.Repo.Migrations.AddStepsDoneToStudioRuns do
  use Ecto.Migration

  # What a row of a list says about a run, as numbers on its own row: how many
  # steps it has taken and how many of the experiment's episodes those steps
  # walked through.
  #
  # Both used to be counted from the transcript, which is why a page of runs
  # read every log on it: a run of 4 789 steps carries 53 MB of log, and a page
  # of twenty-five of them is what made `/runs` wait out the fifteen seconds a
  # connection may be checked out for.
  def up do
    alter table(:studio_runs) do
      add :steps_done, :integer, null: false, default: 0
      add :episodes_done, :integer, null: false, default: 0
    end

    # A run recorded before these columns existed has its log written and its
    # counts missing, and counting them once here is what keeps an old run from
    # reporting zero steps from a list. Each adapter counts its own array:
    # `jsonb` on Postgres, JSON text on SQLite — and the episodes are counted
    # the way `RunHistory.episodes_run/1` counts them: distinct, not last.
    execute backfill_sql()
  end

  def down do
    alter table(:studio_runs) do
      remove :steps_done
      remove :episodes_done
    end
  end

  defp backfill_sql do
    case ExTbpMonty.Database.repo_module().__adapter__() do
      Ecto.Adapters.Postgres ->
        "UPDATE studio_runs SET steps_done = jsonb_array_length(log), " <>
          "episodes_done = (SELECT count(DISTINCT step) FROM jsonb_array_elements(log) AS step " <>
          "WHERE step ? 'episode')"

      _sqlite ->
        "UPDATE studio_runs SET steps_done = json_array_length(log), " <>
          "episodes_done = (SELECT count(DISTINCT json_extract(step.value, '$.episode')) " <>
          "FROM json_each(log) AS step)"
    end
  end
end
