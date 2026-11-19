defmodule ExTbpMontyWeb.RunFramesController do
  @moduledoc """
  A run's pictures and its videos, handed back as the files they are.

  A step's two pictures per sensor are kept under the run's own directory rather
  than in the record: ten kilobytes a step in a jsonb value is what put a
  twenty-thousand-step run past Postgres's ceiling, where the store fails and the
  run ends up with no record at all. A replay asks for the step it shows, so that
  is what this serves.

  What is *behind* a picture's name changed and this route did not: a run now
  keeps one video a sensor instead of a file a step — 215 304 files taking 882 MB
  for 48.7 MB of pixels, on one measured run — so the frame is decoded out of the
  video that holds it. `Artifacts.frame_bytes/2` is where that choice lives; a run
  written before the change still has its files, and both answer here.

  The video itself is served beside its frames, because a run is also something a
  person watches: `watch/2` sends the file with the range handling a player needs
  to seek in it.

  Nothing is looked up and no path is built from the request: the id must be one,
  and a name is parsed and then resolved inside that run's directory. A name that
  is not one of the run's pictures or videos is a 404 — there is nothing to
  escape to.

  The record is deliberately not consulted. It was, to refuse an id that never
  ran, and that one query cost half a second per picture while a run wrote a row
  a step: measured, a 404 for an absent run took as long as the 116-byte PNG
  beside it, six pictures at three steps a second never finished loading, and the
  run page flickered between a picture and an empty box. A run that has no
  directory has no pictures in it, which the lookup already answers.
  """

  use ExTbpMontyWeb, :controller

  alias ExTbpMontyWeb.RangeRequest
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

  @doc """
  Sends one of a run's videos, so a browser can play it and scrub it.

  Range requests are answered here rather than by `Plug.Static`, which serves a
  directory fixed when the endpoint was built, and a run's videos are written
  wherever the deployment says. A player asks for a range before it plays — and a
  different range on every seek — so a `200` with the whole file is a video that
  plays but cannot be scrubbed.
  """
  @spec watch(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def watch(conn, %{"id" => id, "path" => segments}) do
    name = Enum.join(segments, "/")

    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, path} <- Artifacts.video_file(uuid, name),
         {:ok, size} <- size_of(path) do
      conn
      |> put_resp_content_type("video/mp4")
      |> put_resp_header("accept-ranges", "bytes")
      # A video only grows while its run steps, and a player that is seeking must
      # not be handed a copy a proxy cached an hour ago.
      |> put_resp_header("cache-control", "no-cache")
      |> send_bytes(path, size)
    else
      _missing -> send_resp(conn, :not_found, "no such video")
    end
  end

  defp size_of(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> {:ok, size}
      _unreadable -> :error
    end
  end

  # The path is `Artifacts.video_file/2`'s: it expands both sides, keeps the
  # candidate inside the directory of a run named by a UUID, and answers only for
  # a regular `.mp4` there — so `..` in a name is `:error`, not a file.
  # sobelow_skip ["Traversal.SendFile"]
  defp send_bytes(conn, path, size) do
    case RangeRequest.parse(get_req_header(conn, "range"), size) do
      {:ok, first, last} ->
        conn
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
        |> send_file(206, path, first, last - first + 1)

      :whole ->
        send_file(conn, 200, path)

      :unsatisfiable ->
        conn
        |> put_resp_header("content-range", "bytes */#{size}")
        |> send_resp(416, "")
    end
  end
end
