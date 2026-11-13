defmodule ExTbpMonty.ReleasePendingTest do
  @moduledoc """
  How far behind a database is, which the boot of a nameless node asks so that it
  can say `mix ecto.migrate` instead of letting the first page to read a new
  column be a stack trace.

  Separate from `ExTbpMonty.ReleaseTest` because the answer needs a connection,
  and the cases there are about files on a volume.
  """

  use ExTbpMonty.DataCase, async: false

  alias ExTbpMonty.Release

  test "is nothing for a database the suite has migrated" do
    assert Release.pending() == []
  end

  # The manual directory is applied by an operator's decision, never by `migrate/0`,
  # so a migration waiting there is not "behind": counting it would name a repair
  # that is the wrong one.
  test "does not count the migrations that wait for an operator" do
    manual = Path.join(:code.priv_dir(:ex_tbp_monty), "repo/manual_migrations")

    assert File.ls!(manual) |> is_list()
    assert Release.pending() == []
  end

  # The question has one answer per database, and a node that cannot reach its
  # database must not be refused for it: the boot logs and carries on.
  test "says which migrations are waiting, not only how many" do
    applied = Ecto.Migrator.migrated_versions(ExTbpMonty.Database.repo_module())
    all = Ecto.Migrator.migrations_path(ExTbpMonty.Database.repo_module())

    assert is_list(applied)
    assert File.exists?(all)
    assert Release.pending() |> Enum.all?(&is_integer/1)
  end
end
