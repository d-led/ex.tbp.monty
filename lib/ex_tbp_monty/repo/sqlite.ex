defmodule ExTbpMonty.Repo.SQLite do
  @moduledoc """
  The repo used when no `DATABASE_URL` is set: the runs live in a file.

  One of the two compiled repos behind `ExTbpMonty.Repo`; see that module for
  why there are two.
  """

  use Ecto.Repo,
    otp_app: :ex_tbp_monty,
    adapter: Ecto.Adapters.SQLite3

  # The file is named when the repo starts, not when it is compiled: a path
  # written into the build is the *build machine's* home directory, and a window
  # shipped from one machine would look for its runs in another machine's
  # folder. A configured `:database` — what `config/runtime.exs` sets, and what a
  # deployment that mounts a volume passes — always wins; this is the answer for
  # the callers that reach the repo with only what the application was compiled
  # with (`mix ecto.*` in the desktop build, for one).
  @impl true
  def init(_type, config) do
    case Keyword.fetch(config, :database) do
      {:ok, _named} -> {:ok, config}
      :error -> {:ok, Keyword.put(config, :database, Monty.Paths.database())}
    end
  end
end
