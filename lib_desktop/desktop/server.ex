defmodule ExTbpMonty.Desktop.Server do
  @moduledoc """
  The address the window opens.

  A port of its own rather than a shared one: 4000 belongs to whoever asked for
  it first and 4001 is the workspace's. This one is fixed at 42_800, because
  the MCP endpoint on `/mcp/config` is a URL a person pastes into a client once,
  and a client that has to be re-pointed at every launch is not configured. When
  that port is taken — by a second copy of this application or by anything else
  — the operating system picks one instead and the announcement carries it, since
  a fixed port alone would make the second copy the one that fails.

  The line on stdout is the whole contract with the window
  (`src-tauri/src/main.rs` reads until it sees this prefix and points a webview
  at what follows), which is why it is one function with one shape.
  """

  require Logger

  @prefix "desktop ui: "
  @loopback {127, 0, 0, 1}
  @preferred_port 42_800
  @env_var "MONTY_DESKTOP_PORT"
  @settings_name "desktop_port"

  @doc "The prefix a window reads the address from."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc """
  A port for this launch.

  The preferred one when it can be had, otherwise one the operating system hands
  out. Which of the two it was is not something the caller has to know: the
  announcement says the address either way.
  """
  @spec choose_port(Path.t() | nil) :: :inet.port_number()
  def choose_port(path \\ nil) do
    port = preferred_port(path || settings_file())

    if free?(port), do: port, else: taken(port)
  end

  @doc """
  The port asked for, before anything is bound: the environment, then the
  settings file, then the default.

  Read at launch rather than compiled in, so changing it takes an edit and a
  restart, not a rebuild.
  """
  @spec preferred_port(Path.t()) :: :inet.port_number()
  def preferred_port(path) do
    case asked_for(path) do
      {:ok, port} -> port
      :error -> @preferred_port
    end
  end

  @doc "Where the port setting is read from: one line in the application's folder."
  @spec settings_file() :: Path.t()
  def settings_file, do: Path.join(Monty.Paths.root(), @settings_name)

  # The first place that names a port is the answer, and a place that names
  # something which is not one is passed over rather than obeyed.
  defp asked_for(path) do
    case from_env() do
      {:ok, _port} = found -> found
      :error -> from_file(path)
    end
  end

  # A second copy has to start somewhere, and the port it wanted is the one thing
  # it cannot have.
  defp taken(port) do
    Logger.warning("port #{port} is taken; asking the operating system for another one")

    ephemeral_port()
  end

  # Asked of the operating system by opening and closing a socket, which is the
  # only way to know a port is free before the listener that will use it exists.
  # Nothing is held for the window's lifetime: the endpoint binds moments later,
  # and if something took the port in between the endpoint fails to start and says
  # so — rather than the window showing a page that is not ours.
  defp ephemeral_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: @loopback, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp free?(port) do
    case :gen_tcp.listen(port, [:binary, ip: @loopback, active: false]) do
      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  defp from_env do
    case System.get_env(@env_var) do
      nil -> :error
      value -> parse(value, "#{@env_var} is #{inspect(value)}")
    end
  end

  defp from_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        value = String.trim(contents)
        parse(value, "#{path} says #{inspect(value)}")

      # No file, or one this process may not read: neither is a reason to refuse
      # to start.
      {:error, _reason} ->
        :error
    end
  end

  defp parse(value, complaint) do
    # Underscores are allowed because that is how the notes beside this code write
    # a port, and a person copying one should not be told it is not a number.
    case Integer.parse(String.replace(value, "_", "")) do
      {port, ""} when port in 1..65_535 -> {:ok, port}
      _ -> ignored(complaint)
    end
  end

  defp ignored(complaint) do
    Logger.warning(complaint <> ", which is not a port number; ignoring it")
    :error
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
