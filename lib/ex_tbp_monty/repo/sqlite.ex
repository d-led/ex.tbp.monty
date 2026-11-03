defmodule ExTbpMonty.Repo.SQLite do
  @moduledoc """
  The repo used when no `DATABASE_URL` is set: the runs live in a file.

  One of the two compiled repos behind `ExTbpMonty.Repo`; see that module for
  why there are two.
  """

  use Ecto.Repo,
    otp_app: :ex_tbp_monty,
    adapter: Ecto.Adapters.SQLite3
end
