defmodule ExTbpMonty.Repo.Migrations.AddOrderedExperimentIndexToStudioRuns do
  use Ecto.Migration

  # A page that lists one experiment's runs asks for them newest first, and the
  # indexes this table had — on `experiment`, and on `(experiment, episode)` —
  # answer half of that: the database searched the experiment's rows by index and
  # then sorted them itself, in a temporary b-tree, which meant reading every row
  # of the experiment to get its `inserted_at`. On the 1.4 GB SQLite file this was
  # measured against, that query took **4.5 s**, where the same query over ids
  # alone took 3 ms — and it was 3.0 s of the experiment page's 3.0 s mount. The
  # plan said so: `SEARCH … USING INDEX studio_runs_experiment_episode_index`
  # followed by `USE TEMP B-TREE FOR ORDER BY`.
  #
  # Both columns in one index answer both halves — the filter and the order — so
  # the limit is reached after twenty index entries instead of after every row.
  def change do
    create index(:studio_runs, [:experiment, :inserted_at])
  end
end
