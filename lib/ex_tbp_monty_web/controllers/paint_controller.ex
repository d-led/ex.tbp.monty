defmodule ExTbpMontyWeb.PaintController do
  @moduledoc """
  What the page in the window drew, as the page itself reports it.

  Every other check of a desktop build asks the *server* a question: the boot
  check fetches `/health`, then `/prerequisites`. Both answered, and both were
  green, on a build whose window judged its own page a foreign link and opened
  the browser instead — the server was fine and the person saw nothing. This is
  the one question only a drawn page can answer, and the sibling project learned
  it the same way.

  The report is what `Layouts.Painted` sends once the first frame is on screen:
  the address, the document's title, the page's heading, and the ids of the
  elements that are actually in the page. `scripts/smoke-window.sh` waits for it,
  and a page that loads without a heading or without the boxes a person fills in
  is not the screen this build promises.

  Only a window's sidecar answers: `GET` and `POST` are 404 anywhere else, so a
  deployment has no endpoint that lets a request write into its memory.
  """

  use ExTbpMontyWeb, :controller

  @key {__MODULE__, :last}

  # Enough to recognise a screen, not a serialisation of the DOM: the longest
  # ids here are a page's own (`free-space-volume`, `prereq-monty_data`), and a
  # report longer than this is a page nobody meant to send.
  @most_marks 80
  @mark ~r/^[A-Za-z0-9_:.\-]{1,120}$/

  plug :only_from_a_window

  @doc "Records what the page in the window drew."
  @spec record(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def record(conn, params) do
    :persistent_term.put(@key, %{
      at: DateTime.utc_now(),
      path: said(params["path"], 200),
      title: said(params["title"], 200),
      heading: said(params["heading"], 300),
      marks: marks(params["marks"])
    })

    send_resp(conn, :no_content, "")
  end

  @doc """
  Answers the last report as four lines, or 404 when no page has drawn yet.

  Lines rather than JSON because the reader is a shell script: `sed -n
  's/^heading: //p'` is the whole of its parsing, and a failed check can print
  the report as it arrived.
  """
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    conn = put_resp_content_type(conn, "text/plain")

    case :persistent_term.get(@key, nil) do
      nil ->
        send_resp(conn, :not_found, "no page has reported what it drew")

      report ->
        send_resp(conn, :ok, [
          "path: ",
          report.path,
          "\ntitle: ",
          report.title,
          "\nheading: ",
          report.heading,
          "\nmarks: ",
          Enum.join(report.marks, ","),
          "\n"
        ])
    end
  end

  # There is one window: last report wins, and a page that drew twice says the
  # same thing twice.
  #
  # `:persistent_term` rather than a process, because this is a handful of writes
  # per session in a build that has no other use for a supervisor, and because a
  # desktop deployment has no other place to keep it: no database row for what a
  # window painted, and a file would outlive the window it describes.
  defp said(value, limit) when is_binary(value), do: String.slice(value, 0, limit)
  defp said(_value, _limit), do: ""

  defp marks(values) when is_list(values) do
    values
    |> Enum.filter(&(is_binary(&1) and Regex.match?(@mark, &1)))
    |> Enum.take(@most_marks)
  end

  defp marks(_values), do: []

  defp only_from_a_window(conn, _options) do
    if ExTbpMontyWeb.Window.mode?() do
      conn
    else
      conn |> send_resp(:not_found, "this server has no window") |> halt()
    end
  end
end
