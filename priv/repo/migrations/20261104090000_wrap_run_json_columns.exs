defmodule ExTbpMonty.Repo.Migrations.WrapRunJsonColumns do
  use Ecto.Migration

  # A run's log and timeline are arrays of objects. Postgres could keep them as
  # `jsonb[]`; SQLite has no arrays at all, and one JSON document holds the same
  # data on both. The tables are created with the portable type now, so this is
  # only for a Postgres that was created before that.
  #
  # `to_jsonb` of a `jsonb[]` is a JSON array of its elements, so the rows keep
  # their shape and their order.
  def up do
    if postgres?() do
      execute "ALTER TABLE studio_runs ALTER COLUMN log TYPE jsonb USING to_jsonb(log)"
      execute "ALTER TABLE studio_runs ALTER COLUMN timeline TYPE jsonb USING to_jsonb(timeline)"
    end
  end

  # There is no array to go back to: the shape is the JSON document now, on both
  # databases. Going back would mean a Postgres-only column type that SQLite
  # cannot have and that nothing reads.
  def down do
    raise "studio_runs.log and .timeline are one JSON document each, on every database"
  end

  defp postgres?, do: adapter() == Ecto.Adapters.Postgres

  # The repo this instance was started with — the migration may be running
  # against either, and asking a module name that no longer exists would answer
  # "not Postgres" and skip the rewrite on the database that needs it.
  defp adapter, do: ExTbpMonty.Database.repo_module().config()[:adapter]
end
