defmodule Monty.Simulators.Port.Environment do
  @moduledoc """
  A simulator process on the other side of this port.

  The world Monty needs is Python — MuJoCo or Habitat — and it cannot run in the
  BEAM. This is the Elixir half of that boundary: it owns the operating-system
  process, sends it one request at a time, and answers the payloads
  `Monty.Runtime.Step` already expects (`observations`,
  `proprioceptive_state`). What the two say to each other is
  `Monty.Simulators.Port.Protocol`.

  One request in flight at a time. A simulator advances its own state, so two
  steps cannot be interleaved, and a step that does not answer in time is an
  error rather than something to carry on past: a step that silently produced no
  observation would be counted as a step the model took.

  Nothing here is a ported module — Monty's simulators are not part of the core
  — so it does not appear in the module map.
  """

  use GenServer

  require Logger

  alias Monty.Simulators.Port.Protocol

  @default_timeout 30_000

  @type options :: [
          command: [String.t()],
          sensor_ids: [String.t()],
          timeout: timeout(),
          name: GenServer.name() | nil
        ]

  @spec start_link(options()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: options[:name])
  end

  @doc """
  Starts the simulator afresh, for the first step of an episode.
  """
  @spec reset(GenServer.server()) :: :ok | {:error, term()}
  def reset(server), do: GenServer.call(server, :reset, :infinity)

  @doc """
  One step of the world: the actions the model chose, the observation it gets.
  """
  @spec step(GenServer.server(), [Monty.Frameworks.Actions.Action.t()]) ::
          {:ok, map(), map()} | {:error, term()}
  def step(server, actions), do: GenServer.call(server, {:step, actions}, :infinity)

  @doc "Closes the port: the simulator process is stopped with it."
  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server)

  # -- the process ----------------------------------------------------------

  @impl true
  def init(options) do
    state = %{
      options: options,
      port: nil,
      next_id: 1,
      timeout: Keyword.get(options, :timeout, @default_timeout)
    }

    case open(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:reset, _from, state) do
    case request(state, {:reset, Keyword.get(state.options, :sensor_ids, [])}) do
      {:ok, _observations, _proprioceptive_state, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:step, actions}, _from, state) do
    case request(state, {:step, actions}) do
      {:ok, observations, proprioceptive_state, state} ->
        # The reply carries Monty's own maps; the rest of the port works in
        # `AgentState`/`SensorState`, so the translation happens here, once.
        {:reply, {:ok, observations, Protocol.proprioceptive_state(proprioceptive_state)}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def terminate(_reason, %{port: nil}), do: :ok

  def terminate(_reason, %{port: port}) do
    Port.close(port)
    :ok
  end

  # -- talking to the simulator ---------------------------------------------

  defp open(%{options: options} = state) do
    [executable | arguments] = Keyword.fetch!(options, :command)

    port =
      Port.open({:spawn_executable, executable_path(executable)}, [
        :binary,
        :exit_status,
        {:packet, 4},
        args: arguments ++ Keyword.get(options, :args, []),
        cd: Keyword.get(options, :cd, File.cwd!())
      ])

    {:ok, %{state | port: port}}
  rescue
    error in [ArgumentError, ErlangError] -> {:error, {:cannot_start, error}}
  end

  defp executable_path(executable) do
    System.find_executable(executable) || raise ArgumentError, "cannot find #{executable}"
  end

  defp request(%{port: nil} = state, _request), do: {:error, :closed, state}

  defp request(state, request) do
    id = state.next_id
    body = Jason.encode!(Protocol.request(id, request))

    # `{:packet, 4}` adds the length prefix, and strips it from what comes back.
    Port.command(state.port, body)

    state = %{state | next_id: id + 1}
    await_reply(state, id)
  end

  defp await_reply(state, id) do
    receive do
      {port, {:data, body}} when port == state.port ->
        case Protocol.reply(body, id) do
          {:ok, observations, proprioceptive_state} ->
            {:ok, observations, proprioceptive_state, state}

          {:error, reason} ->
            {:error, reason, state}
        end

      {port, {:exit_status, status}} when port == state.port ->
        {:error, {:simulator_exited, status}, %{state | port: nil}}
    after
      state.timeout ->
        # The simulator is out of step with the model, and no later reply can be
        # attributed to the right request; stop it rather than carry on.
        Logger.error("simulator did not answer request #{id} within #{state.timeout}ms")
        stop_port(state)
        {:error, :timeout, %{state | port: nil}}
    end
  end

  defp stop_port(%{port: nil}), do: :ok

  defp stop_port(%{port: port}) do
    Port.close(port)
    :ok
  end
end
