defmodule ExTbpMonty.Repo.Postgres do
  @moduledoc """
  The repo used when `DATABASE_URL` names a Postgres.

  One of the two compiled repos behind `ExTbpMonty.Repo`; see that module for
  why there are two.
  """

  use Ecto.Repo,
    otp_app: :ex_tbp_monty,
    adapter: Ecto.Adapters.Postgres
end
