defmodule ExTbpMontyWeb.HealthController do
  @moduledoc """
  Whether the application is up, in the one form a monitor can act on.

  It answers 200 when the application can reach its database and 503 when it
  cannot: a probe that always says 200 is a probe that tells you the web server
  started, which is the least interesting thing that can fail.
  """

  use ExTbpMontyWeb, :controller

  @doc "Answers whether the database is reachable."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    case ExTbpMonty.Repo.query("select 1") do
      {:ok, _result} ->
        conn |> put_status(:ok) |> json(%{status: "ok"})

      {:error, _reason} ->
        conn |> put_status(:service_unavailable) |> json(%{status: "unavailable"})
    end
  end
end
