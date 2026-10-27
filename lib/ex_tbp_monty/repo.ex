defmodule ExTbpMonty.Repo do
  use Ecto.Repo,
    otp_app: :ex_tbp_monty,
    adapter: Ecto.Adapters.Postgres
end
