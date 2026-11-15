defmodule ExTbpMonty.Desktop.Plugins do
  @moduledoc """
  The two sample plugin nodes the window carries: where they are, how to start
  them, and how to stop them with the window.

  They are **releases of their own projects**, in `plugins/` beside the window's
  own release (`Contents/Resources/plugins` in a `.app`, `plugins\\` beside the
  window everywhere else), and starting one is starting a second VM: this module
  runs the release's own launcher and gives it the two things a peer needs — the
  node name to join (`MONTY_SEEDS`) and the cookie this window's node uses, which
  every release otherwise answers with one of its own (`releases/COOKIE`, written
  per build) and a peer then refuses. It also hands the child a release
  environment of its own: this VM's `RELEASE_*` describe *this* release, and a
  child that inherits them reads the wrong version number and dies on its first
  line — see `environment/1`.

  ## Why a process rather than a function

  What was started has to be stopped. The window is the only thing that knows
  these two nodes are its own — it started them — and a window that closes on
  them leaves two VMs holding ports and a database nobody can see. So the starts
  are a `GenServer`'s state, and `shutdown/0` — called from the desktop
  application's `stop/1`, which is the orderly path out of the VM — stops the
  nodes over `rpc` before the sidecar goes. A window killed outright leaves them,
  which `plugins/start-plugins.* --stop` is for.

  ## What it refuses

  A node with no name cannot be joined, so `start/0` says that instead of
  launching two nodes that would then find nobody. And nothing here takes a path
  or a command from a page: the two launchers are the ones in `plugins/`, found
  by this module, so the control cannot become a way to run something else.
  """

  # The behaviour a page sees, and the only reason this module is named anywhere
  # outside itself: `config/desktop.exs` hands it to `ExTbpMonty.SamplePlugins`.
  @behaviour ExTbpMonty.SamplePlugins

  use GenServer

  require Logger

  @examples ["example_plugin", "flyverse_plugin"]

  # How long a stop may take. Both nodes are idle when a window closes, and a
  # window that waits on them for longer than this is a window that hangs.
  @stop_timeout 5_000

  @doc "The name this server is registered under."
  @spec name() :: module()
  def name, do: __MODULE__

  @doc """
  Starts the server, unlinked.

  Unlinked on purpose: a control that can take the sidecar down with it is worse
  than a control that does nothing. `shutdown/0` is what stops the nodes, called
  from the application's own `stop/1`.
  """
  @spec start_server() :: GenServer.on_start()
  def start_server, do: GenServer.start(__MODULE__, [], name: name())

  @impl true
  def init(_args), do: {:ok, %{started: [], ports: %{}, saying: %{}}}

  @impl true
  def handle_call(:start, _from, state) do
    case join_target() do
      {:error, sentence} ->
        {:reply, {:error, sentence}, state}

      {:ok, target} ->
        launched = @examples |> Enum.map(&one(&1, target)) |> Enum.reject(&is_nil/1)
        names = Enum.map(launched, fn {_example, name, _port} -> to_string(name) end)

        {:reply, {:ok, names}, remember(launched, state)}
    end
  end

  def handle_call(:stop, _from, state) do
    Enum.each(state.started, &stop_one/1)
    {:reply, :ok, %{state | started: []}}
  end

  @impl ExTbpMonty.SamplePlugins
  @doc "Starts the sample plugin nodes, joined to this node."
  @spec start() :: {:ok, [String.t()]} | {:error, String.t()}
  def start, do: call(:start, {:error, "the sample plugin server is not running"})

  @impl ExTbpMonty.SamplePlugins
  @doc "Stops the ones this node started."
  @spec stop() :: :ok
  def stop, do: call(:stop, :ok)

  @doc """
  Stops them as the window goes, without waiting for a page.

  Called from the desktop application's `stop/1`: the supervisor is already
  shutting down, so this is a direct call with a bound rather than a `call/3`
  that could wait on a dying server.
  """
  @spec shutdown() :: :ok
  def shutdown do
    case Process.whereis(name()) do
      nil -> :ok
      pid -> GenServer.call(pid, :stop, @stop_timeout)
    end
  catch
    :exit, _gone -> :ok
  end

  @impl ExTbpMonty.SamplePlugins
  @doc "Whether the two launchers are beside this window's release."
  @spec available?() :: boolean()
  def available?, do: here?()

  @doc """
  Where the plugin releases are: `plugins/` beside this release's root.

  `MONTY_STUDIO_PLUGINS` overrides it, which is how a checkout points the same
  code at `_build/desktop/plugins` — and how a test points it at a temporary
  folder.
  """
  @spec root() :: Path.t()
  def root do
    case System.get_env("MONTY_STUDIO_PLUGINS") do
      nil -> Path.join(release_root(), "../plugins")
      configured -> configured
    end
  end

  defp call(message, nothing_running) do
    case Process.whereis(name()) do
      nil -> nothing_running
      pid -> GenServer.call(pid, message, @stop_timeout)
    end
  end

  defp here? do
    Enum.all?(@examples, fn example -> File.dir?(Path.join([root(), example, "bin"])) end)
  end

  # The node both examples are told to dial. `sname` gives this window a host, and
  # a window started with `MONTY_STUDIO_CLUSTER=0` has none — the one refusal that
  # is not a failure.
  defp join_target do
    case ExTbpMonty.Node.address(node()) do
      nil ->
        {:error,
         "this window is not a named node, so the sample plugins would have nobody to join. " <>
           "Start it without MONTY_STUDIO_CLUSTER=0."}

      address ->
        {:ok, address}
    end
  end

  # One launcher, started in its release's own folder with the two variables a
  # peer needs. A node that is already up is left alone — pressing the control
  # twice is not an error.
  defp one(example, target) do
    node_name = node_name(example)

    if running?(node_name) do
      {example, node_name, nil}
    else
      case launch(example, target) do
        {:ok, port} ->
          {example, node_name, port}

        {:error, sentence} ->
          Logger.warning("the sample plugin node #{example} did not start: #{sentence}")
          nil
      end
    end
  end

  # What was started is remembered by name — pressing the control twice is not an
  # error — and by port, because a node that dies has to be named in the log, and
  # the pipe that would have said why is drained at `:debug`.
  defp remember(launched, state) do
    Enum.reduce(launched, state, fn
      {_example, name, nil}, state ->
        %{state | started: Enum.uniq(state.started ++ [name])}

      {example, name, port}, state ->
        %{
          state
          | started: Enum.uniq(state.started ++ [name]),
            ports: Map.put(state.ports, port, example)
        }
    end)
  end

  defp launch(example, target) do
    release = Path.join(root(), example)
    launcher = Path.join([release, "bin", executable(example)])
    {program, leading} = program(launcher)

    port =
      Port.open({:spawn_executable, program}, [
        :binary,
        :exit_status,
        :hide,
        args: leading ++ ["start"],
        cd: release,
        env: environment(target)
      ])

    {:ok, port}
  rescue
    error -> {:error, Exception.message(error)}
  end

  # A `.bat` is not an executable image: Windows has to be asked to run one, so
  # the launcher is an argument to `cmd` there and the program everywhere else.
  defp program(launcher) do
    case :os.type() do
      {:win32, _} -> {System.find_executable("cmd") || "cmd.exe", ["/c", launcher]}
      _ -> {launcher, []}
    end
  end

  @doc """
  The environment a sample plugin's launcher is started with, given the node it
  should join.

  Two variables are the child's to be given — the node to dial and the cookie to
  dial it with — and the rest of this VM's `RELEASE_*` are the child's to not
  inherit. They describe *this* release, and a launcher defaults a variable only
  when it is unset **or empty**, so each one is passed empty and the plugin's
  launcher reads its own `start_erl.data` and its own name instead.

  Inherited whole, `RELEASE_VSN` sent the child looking for
  `releases/<this release's version>/env.sh` inside a release that never had that
  folder: it died in its first line, and all the window's log showed was a
  control that reported two nodes and a cluster that stayed empty.
  """
  @spec environment(String.t()) :: [{charlist(), charlist()}]
  def environment(target) do
    blanked =
      for {name, _value} <- System.get_env(),
          String.starts_with?(name, "RELEASE_"),
          name != "RELEASE_COOKIE",
          do: {to_charlist(name), ~c""}

    blanked ++
      [
        {~c"MONTY_SEEDS", to_charlist(target)},
        {~c"RELEASE_COOKIE", to_charlist(cookie())}
      ]
  end

  # A plugin node writes its whole log to a pipe this process holds, and a port
  # nobody reads fills that pipe — the child then blocks on a write and looks like
  # a node that started and hung. So the lines are drained, at `:debug`: the
  # window's own log already carries the sidecar's.
  @impl true
  def handle_info({port, {:data, line}}, state) do
    line = String.trim_trailing(line)
    Logger.debug(fn -> "sample plugin: " <> line end)
    {:noreply, %{state | saying: Map.put(state.saying, port, line)}}
  end

  def handle_info({port, {:exit_status, status}}, state) do
    {example, ports} = Map.pop(state.ports, port, "a sample plugin node")
    {said, saying} = Map.pop(state.saying, port)
    state = %{state | ports: ports, saying: saying}

    if status == 0 do
      {:noreply, state}
    else
      # The child's own last words: a launcher that dies on its first line is how
      # this failed once, and the pipe is drained at `:debug`.
      Logger.warning("#{example} exited with status #{status}: #{said || "no output"}")
      {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # A release that is already up answers a connection; one that is not answers
  # nothing. That is the only question a second press needs to ask.
  defp running?(node_name) do
    ExTbpMonty.Node.distributed?() and Node.connect(node_name) == true
  end

  defp stop_one(node_name) do
    if Node.connect(node_name) == true do
      _ = :rpc.call(node_name, System, :stop, [], @stop_timeout)
    end

    :ok
  end

  defp node_name(example), do: :"#{example}@#{host()}"

  defp host do
    case ExTbpMonty.Node.address(node()) do
      nil -> "nohost"
      address -> address |> String.split("@") |> List.last()
    end
  end

  # The cookie this node answers with. `releases/COOKIE` is not always the
  # answer — `config/runtime.exs` replaces it from `MONTY_CLUSTER_SECRET` — so the
  # node is asked instead of its files.
  defp cookie, do: Node.get_cookie() |> Atom.to_string()

  defp release_root do
    :ex_tbp_monty |> Application.app_dir() |> Path.join("../../..") |> Path.expand()
  rescue
    # Not a release and not a built tree: there is nowhere for `plugins/` to be.
    ArgumentError -> File.cwd!()
  end

  defp executable(example) do
    case :os.type() do
      {:win32, _} -> "#{example}.bat"
      _ -> example
    end
  end
end
