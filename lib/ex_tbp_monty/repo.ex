defmodule ExTbpMonty.Repo do
  @moduledoc """
  The database this instance keeps its runs in, whichever that is.

  Ecto binds a repo to one adapter at compile time: `use Ecto.Repo` names the
  adapter, and the supervisor calls *that* module's `init/1` at boot, so a
  runtime `adapter:` in the configuration is read by nobody. One image serving
  SQLite by default and Postgres when `DATABASE_URL` is set therefore needs two
  compiled repos — `ExTbpMonty.Repo.Postgres` and `ExTbpMonty.Repo.SQLite` — and
  one name for the application to call them by: this module.

  Every call the application makes is forwarded to the repo chosen at boot
  (`ExTbpMonty.Database.repo_module/0`), which is also the one `Application`
  starts and the one Oban and the migrator are given. Adding a call means adding
  a line here; forgetting one is a compile error, not a silent no-op.
  """

  @doc "The repo module this instance uses."
  @spec current() :: module()
  def current, do: ExTbpMonty.Database.repo_module()

  @spec config() :: keyword()
  def config, do: current().config()

  @spec config(atom()) :: term()
  def config(key), do: current().config(key)

  @spec transaction((-> term()) | Ecto.Multi.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def transaction(fun_or_multi, opts \\ []), do: current().transaction(fun_or_multi, opts)

  @spec rollback(term()) :: no_return()
  def rollback(value), do: current().rollback(value)

  @spec all(Ecto.Queryable.t(), keyword()) :: [term()]
  def all(queryable, opts \\ []), do: current().all(queryable, opts)

  @spec one(Ecto.Queryable.t(), keyword()) :: term() | nil
  def one(queryable, opts \\ []), do: current().one(queryable, opts)

  @spec get(Ecto.Queryable.t(), term(), keyword()) :: struct() | nil
  def get(queryable, id, opts \\ []), do: current().get(queryable, id, opts)

  @spec get!(Ecto.Queryable.t(), term(), keyword()) :: struct()
  def get!(queryable, id, opts \\ []), do: current().get!(queryable, id, opts)

  @spec insert(struct() | Ecto.Changeset.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def insert(struct_or_changeset, opts \\ []), do: current().insert(struct_or_changeset, opts)

  @spec update(struct() | Ecto.Changeset.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def update(struct_or_changeset, opts \\ []), do: current().update(struct_or_changeset, opts)

  @spec update!(struct() | Ecto.Changeset.t(), keyword()) :: term()
  def update!(struct_or_changeset, opts \\ []), do: current().update!(struct_or_changeset, opts)

  @spec delete(struct() | Ecto.Changeset.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def delete(struct_or_changeset, opts \\ []), do: current().delete(struct_or_changeset, opts)

  @spec update_all(Ecto.Queryable.t(), keyword() | term(), keyword()) :: non_neg_integer()
  def update_all(queryable, updates, opts \\ []),
    do: current().update_all(queryable, updates, opts)

  # Ecto answers a deletion with the rows it could not leave to the database —
  # nil, or the deleted structs when a query returns them — and the count. The
  # spec said `non_neg_integer()`, so a caller matching the count and the rows
  # (which is what the function does return) was a dialyzer error.
  @spec delete_all(Ecto.Queryable.t(), keyword()) :: {non_neg_integer(), nil | [term()]}
  def delete_all(queryable, opts \\ []), do: current().delete_all(queryable, opts)

  @spec aggregate(Ecto.Queryable.t(), :count | :avg | :sum | :max | :min, term(), keyword()) ::
          term()
  def aggregate(queryable, aggregate, field, opts \\ []),
    do: current().aggregate(queryable, aggregate, field, opts)

  @spec exists?(Ecto.Queryable.t(), keyword()) :: boolean()
  def exists?(queryable, opts \\ []), do: current().exists?(queryable, opts)

  @spec reload(struct() | [struct()], keyword()) :: struct() | [struct()] | nil
  def reload(struct_or_structs, opts \\ []), do: current().reload(struct_or_structs, opts)

  @spec preload(struct() | [struct()], term(), keyword()) :: struct() | [struct()]
  def preload(struct_or_structs, preloads, opts \\ []),
    do: current().preload(struct_or_structs, preloads, opts)

  @spec query(String.t(), list(), keyword()) :: {:ok, term()} | {:error, term()}
  def query(sql, params \\ [], opts \\ []), do: current().query(sql, params, opts)

  @spec to_sql(:all | :update_all | :delete_all, Ecto.Queryable.t()) :: {String.t(), list()}
  def to_sql(operation, queryable), do: current().to_sql(operation, queryable)
end
