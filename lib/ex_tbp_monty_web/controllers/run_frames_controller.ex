defmodule ExTbpMontyWeb.RunFramesController do
  @moduledoc """
  A picture one run kept, handed back as the PNG it is.

  A step's two pictures per sensor are written under the run's own directory
  rather than into the record: ten kilobytes a step in a jsonb value is what put
  a twenty-thousand-step run past Postgres's ceiling, where the store fails and
  the run ends up with no record at all. A replay asks for the step it shows, so
  that is what this serves.

  Two things are checked and neither is a path built from the request: the run is
  looked up by id, which only answers for a run that exists, and the picture's
  path is resolved and then checked to still be inside that run's directory. A
  path that is not one of the run's pictures is a 404 — there is nothing to
  escape to.
  """

  use ExTbpMontyWeb, :controller

  alias Monty.Studio.{Artifacts, RunHistory}

  @doc "Sends one of a run's pictures, or says it is not there."
  # Not a path from the request: `Artifacts.frame_path/2` answers only with a
  # regular file inside the directory of a run named by a UUID, and the content
  # type is the one this route exists to serve.
  # sobelow_skip ["Traversal.SendFile", "XSS.ContentType"]
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id, "path" => segments}) do
    name = Enum.join(segments, "/")

    with true <- RunHistory.exists?(id),
         {:ok, path} <- Artifacts.frame_path(id, name) do
      conn
      |> put_resp_content_type("image/png")
      |> send_file(200, path)
    else
      _missing -> send_resp(conn, :not_found, "no such picture")
    end
  end
end
