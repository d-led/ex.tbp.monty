defmodule ExTbpMonty.Release do
  @moduledoc """
  The entry points a release is driven from: migrations, and the data a run
  reads.

  Migrations live in two directories:

    * `priv/repo/migrations` — schema changes that old and new code can both
      live with. `migrate/0` applies them, and the container runs it on every
      boot before starting the server.
    * `priv/repo/manual_migrations` — slow, destructive or data migrations that
      need an operator's decision. Only `migrate_manual/0` applies them.

  Generating a manual migration and running it:

      mix ecto.gen.migration --migrations-path=priv/repo/manual_migrations backfill_status

      /app/bin/ex_tbp_monty eval "ExTbpMonty.Release.migrate_manual"

  In development and test both directories are applied together
  (`mix ecto.migrate_all`), so nobody has to remember the second one.

  `fetch_prerequisites/0` is the other half of a first start: the image ships
  the software and Monty's config tree, and no data, so the datasets and the
  pretrained model bundles are fetched here — before the server serves, so a
  run cannot be asked for an experiment whose files are still arriving.
  """

  @app :ex_tbp_monty
  @manual_migrations "manual_migrations"

  alias Monty.Prerequisites

  @doc """
  Applies the migrations that are safe to run automatically on deploy.
  """
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      path = Ecto.Migrator.migrations_path(repo)
      {:ok, _repo, _applied} = run_migrations(repo, path)
    end

    :ok
  end

  @doc """
  The automatic migrations this database has not applied.

  A node that runs alone migrates itself at boot only when it was given a name
  (`ExTbpMonty.Application`): a named node owns its own database, while a
  developer's unnamed node is migrated by `mix ecto.migrate`, on purpose. The
  cost of that split is a database that is behind, and the first page to read a
  new column is a stack trace — so the boot asks this, and says what to type.

  The manual directory (`priv/repo/manual_migrations`) is not part of the answer:
  those are not applied automatically anywhere, so "behind" would be a word
  without a repair. Empty for a database that is up to date, which is every
  database a test opens.
  """
  @spec pending() :: [non_neg_integer()]
  def pending do
    load_app()

    repos()
    |> Enum.map(fn repo ->
      path = Ecto.Migrator.migrations_path(repo)

      # At boot the repo is not started yet — `prepare_data_folder/0` runs before
      # the tree — so `with_repo/2` starts it for the question and stops it again.
      # A node that is already running asks directly.
      if Process.whereis(repo) do
        pending_in(repo, path)
      else
        {:ok, _repo, pending} = Ecto.Migrator.with_repo(repo, &pending_in(&1, path))
        pending
      end
    end)
    |> List.flatten()
  end

  # What `migrate/0` would apply and this database has not: the files on disk
  # minus the versions the repository's own migrations table holds.
  defp pending_in(repo, path) do
    applied = MapSet.new(Ecto.Migrator.migrated_versions(repo))

    # `Ecto.Migrator.migrations/2` answers `[{:up | :down, version, name}]`, in
    # the order the files sort: the versions the database is missing are the ones
    # `migrate/0` would apply.
    repo
    |> Ecto.Migrator.migrations(path)
    |> Enum.map(fn {_direction, version, _name} -> version end)
    |> Enum.reject(&MapSet.member?(applied, &1))
  end

  @doc """
  Downloads whatever an experiment needs that is not on disk yet, and waits.

  Nothing is fetched when everything is already there, which is the case on
  every start after the first: the bundles land on a volume. A download that
  does not arrive raises, so a container that runs this before serving stops
  rather than serving runs that cannot read their model.
  """
  @spec fetch_prerequisites() :: :ok
  def fetch_prerequisites do
    {:ok, _apps} = Application.ensure_all_started(@app)

    fetched =
      Prerequisites.all()
      |> Enum.reject(&Prerequisites.present?/1)
      |> Enum.map(&fetch_prerequisite/1)

    case Enum.reject(fetched, &(&1 == :ok)) do
      [] -> :ok
      failures -> raise "#{length(failures)} prerequisite(s) did not arrive: #{inspect(failures)}"
    end
  end

  defp fetch_prerequisite(prerequisite) do
    case Prerequisites.fetch(prerequisite) do
      {:ok, _progress} -> :ok
      {:error, reason} -> {prerequisite.id, reason}
    end
  end

  @doc """
  Applies the migrations that wait for a human: slow, destructive or data-only.
  """
  @spec migrate_manual() :: :ok
  def migrate_manual do
    load_app()

    for repo <- repos() do
      path = Ecto.Migrator.migrations_path(repo, @manual_migrations)
      {:ok, _repo, _applied} = run_migrations(repo, path)
    end

    :ok
  end

  defp run_migrations(repo, path) do
    Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, path, :up, all: true))
  end

  defp repos do
    # The module the instance was started with, not the compile-time list: in a
    # release that can be the SQLite repo, whose migrations are the same files.
    [ExTbpMonty.Database.repo_module()]
  end

  defp load_app do
    Application.load(@app)
  end
end
