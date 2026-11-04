defmodule ExTbpMonty.Desktop.Server do
  @moduledoc """
  The address the window opens.

  A port the operating system hands out rather than a fixed one: 4000 belongs to
  whoever asked for it first, and a second copy of this application must not be
  the thing that kills the first. The line on stdout is the whole contract with
  the window (`src-tauri/src/main.rs` reads until it sees this prefix and points
  a webview at what follows), which is why it is one function with one shape.
  """

  @prefix "desktop ui: "
  @loopback {127, 0, 0, 1}

  @doc "The prefix a window reads the address from."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc """
  A free loopback port.

  Asked of the operating system by opening and closing a socket, which is the
  only way to know a port is free before the listener that will use it exists.
  Nothing is bound here for the window's lifetime: the endpoint is, moments
  later, and if something took the port in between the endpoint fails to start
  and says so — rather than the window showing a page that is not ours.
  """
  @spec choose_port() :: :inet.port_number()
  def choose_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: @loopback, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  @doc """
  Points the endpoint at that port, on loopback and nowhere else.

  The endpoint reads its configuration once, when it starts, so this has to
  happen before the supervisor does — and the URL is written beside the listener
  because LiveView builds its socket address from it, and a socket addressed to
  yesterday's port is a page that loads and never updates.
  """
  @spec configure_endpoint(:inet.port_number()) :: :ok
  def configure_endpoint(port) do
    endpoint = ExTbpMontyWeb.Endpoint
    current = Application.get_env(:ex_tbp_monty, endpoint, [])

    http =
      current
      |> Keyword.get(:http, [])
      |> Keyword.put(:ip, @loopback)
      |> Keyword.put(:port, port)

    Application.put_env(
      :ex_tbp_monty,
      endpoint,
      Keyword.merge(current,
        url: [host: "127.0.0.1", port: port, scheme: "http"],
        http: http,
        server: true
      )
    )

    :ok
  end

  @doc "Says where it listens, in the one shape the window reads."
  @spec announce(:inet.port_number()) :: :ok
  def announce(port), do: IO.puts(@prefix <> "http://127.0.0.1:#{port}/")
end
