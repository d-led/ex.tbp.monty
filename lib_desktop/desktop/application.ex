defmodule ExTbpMonty.Desktop.Application do
  @moduledoc """
  What the window's sidecar starts.

  It is the server's own application tree — the same children, the same
  endpoint, the same LiveViews, the same routes — with two things a server has
  no use for and a window cannot do without: a loopback port the operating
  system hands out, and one line on stdout saying where that port is.

  That is the whole of the desktop build. It adds no screen, because every
  screen the server serves already works in this window: a page that needed a
  second version for the desktop would be a page that had stopped being the same
  application.
  """

  use Application

  alias ExTbpMonty.Desktop.ParentWatch
  alias ExTbpMonty.Desktop.Server

  @impl true
  def start(type, args) do
    # Before the endpoint starts, because the endpoint reads its configuration
    # once; the port is announced after, because only then is something
    # listening on it.
    port = Server.choose_port()
    Server.configure_endpoint(port)
    exit_with_the_window()
    ParentWatch.start_link()

    case ExTbpMonty.Application.start(type, args) do
      {:ok, pid} ->
        Server.announce(port)
        {:ok, pid}

      error ->
        error
    end
  end

  # The window holds this process's standard input open for exactly as long as it
  # is running, so the pipe closing is the window being gone — closed, crashed or
  # force-quit. `RunEvent::Exit` in `src-tauri/src/main.rs` stops the server on
  # the tidy path; this is the one that also covers the untidy one, where a server
  # would otherwise outlive its window holding the database and a port nobody can
  # find again.
  #
  # Only when the window says so (`EX_TBP_MONTY_WINDOW`): a container's standard
  # input is not a pipe to a supervisor, and `/dev/null` closes at once. Starting
  # the release by hand is covered by `ParentWatch`, which needs no pipe.
  defp exit_with_the_window do
    if System.get_env("EX_TBP_MONTY_WINDOW") == "1" do
      Task.start(fn ->
        _ = IO.binread(:stdio, :eof)
        System.stop()
      end)
    end

    :ok
  end

  @impl true
  def config_change(changed, _new, removed) do
    # Phoenix applies the new values itself; the endpoint only has to be told
    # which keys changed and which went, in that order.
    ExTbpMontyWeb.Endpoint.config_change(changed, removed)
  end
end
