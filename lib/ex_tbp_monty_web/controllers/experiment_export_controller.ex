defmodule ExTbpMontyWeb.ExperimentExportController do
  @moduledoc """
  Hands an experiment over as a file.

  A download, not a page: the browser saves it, and what it saved is exactly
  what the studio would compose and Monty would run. It lives outside
  `/experiments/*name` because that address belongs to the LiveView, and because
  a file and a page are different answers to the same question.
  """

  use ExTbpMontyWeb, :controller

  alias Monty.Studio.Drafts

  def show(conn, %{"name" => segments}) do
    name = Enum.join(segments, "/")

    case Drafts.export(name) do
      {:ok, exported} ->
        conn
        |> put_resp_content_type("application/yaml")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{exported.filename}"))
        |> send_resp(200, exported.yaml)

      {:error, message} ->
        conn
        |> put_status(:not_found)
        |> text(message)
    end
  end
end
