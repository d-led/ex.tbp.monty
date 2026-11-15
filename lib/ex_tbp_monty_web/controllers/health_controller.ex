defmodule ExTbpMontyWeb.HealthController do
  @moduledoc """
  Whether the application is up, in the one form a monitor can act on.

  It answers 200 when the application can reach its database and 503 when it
  cannot: a probe that always says 200 is a probe that tells you the web server
  started, which is the least interesting thing that can fail.

  The answer also names the node, because a page served by one of several is a
  page whose reader has to know which — and because the desktop's own boot check
  is how the name its launcher gave it is verified without a window: it asks here
  and reads the answer.
  """

  use ExTbpMontyWeb, :controller

  @doc "Answers whether the database is reachable, and which node answered."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    case ExTbpMonty.Repo.query("select 1") do
      {:ok, _result} ->
        conn |> put_status(:ok) |> json(%{status: "ok", node: answerer()})

      {:error, _reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "unavailable", node: answerer()})
    end
  end

  # `nil` on a node that was never named, which is JSON's `null` and a reader's
  # "this one is not in a cluster".
  defp answerer, do: ExTbpMonty.Node.address(node())
end
