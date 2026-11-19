defmodule ExTbpMontyWeb.RunFramesController do
  @moduledoc """
  A picture one run kept, handed back as the PNG the page draws.

  A step's two pictures per sensor are kept under the run's own directory rather
  than in the record: ten kilobytes a step in a jsonb value is what put a
  twenty-thousand-step run past Postgres's ceiling, where the store fails and the
  run ends up with no record at all. A replay asks for the step it shows, so that
  is what this serves.

  What is *behind* the name changed and this route did not: a run now keeps one
  video a sensor instead of a file a step — 215 304 files taking 882 MB for 48.7
  MB of pixels, on one measured run — so the frame is decoded out of the video
  that holds it. `Artifacts.frame_bytes/2` is where that choice lives; a run
  written before the change still has its files, and both answer here.

  Nothing is looked up and no path is built from the request: the id must be one,
  and the picture's name is parsed and then resolved inside that run's directory.
  A name that is not one of the run's pictures is a 404 — there is nothing to
  escape to.

  The record is deliberately not consulted. It was, to refuse an id that never
  ran, and that one query cost half a second per picture while a run wrote a row
  a step: measured, a 404 for an absent run took as long as the 116-byte PNG
  beside it, six pictures at three steps a second never finished loading, and the
  run page flickered between a picture and an empty box. A run that has no
  directory has no pictures in it, which the lookup already answers.
  """

  use ExTbpMontyWeb, :controller

  alias Monty.Studio.Artifacts

  @doc "Sends one of a run's pictures, or says it is not there."
  # The bytes are this application's own PNG, produced by `Artifacts.frame_bytes/2`
  # for a run named by a UUID in the path, and the content type is the one this
  # route exists to serve.
  # sobelow_skip ["XSS.ContentType"]
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id, "path" => segments}) do
    name = Enum.join(segments, "/")

    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, png} <- Artifacts.frame_bytes(uuid, name) do
      conn
      |> put_resp_content_type("image/png")
      # A step's picture never changes once it is written, and the name says which
      # step it is: a browser that has one need never ask again.
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> send_resp(200, png)
    else
      _missing -> send_resp(conn, :not_found, "no such picture")
    end
  end
end
