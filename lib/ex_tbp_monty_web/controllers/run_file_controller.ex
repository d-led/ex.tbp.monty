defmodule ExTbpMontyWeb.RunFileController do
  @moduledoc """
  A file one run wrote, handed back as the file it is.

  The CSV and JSON a run leaves behind are for reading, diffing and plotting with
  tools this application does not have, so they are served rather than drawn: the
  page links a file, the browser downloads it.

  Two things are checked and neither is a path built from the request: the run is
  looked up by id, which only answers for a run that exists, and the name is
  matched against the names that run's directory actually holds. A name that is
  not a file of that run is a 404 — there is nothing to escape from.
  """

  use ExTbpMontyWeb, :controller

  alias Monty.Studio.{Artifacts, RunHistory}

  @doc "Sends one of a run's files, or says it is not there."
  # The path is not built from the request: `Artifacts.file_path/2` answers only
  # with a name the run's own directory holds, under a directory named by a
  # UUID, and the content type is that name's extension. A name that is not one of
  # the run's files is a 404 before either call.
  # sobelow_skip ["Traversal.SendFile", "XSS.ContentType"]
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id, "name" => name}) do
    with %{} = _run <- RunHistory.get(id),
         {:ok, path} <- Artifacts.file_path(id, name) do
      conn
      |> put_resp_content_type(content_type(name))
      |> send_file(200, path)
    else
      _missing -> send_resp(conn, :not_found, "no such file")
    end
  end

  # What the two artifact kinds are; anything else is the text the log is.
  defp content_type(name) do
    case Path.extname(name) do
      ".csv" -> "text/csv"
      ".json" -> "application/json"
      _other -> "text/plain"
    end
  end
end
