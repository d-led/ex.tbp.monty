defmodule Monty.Runtime.SensorModuleServer do
  @moduledoc """
  One sensor module, one process.

  The process holds the module's state and nothing else: every decision is a
  callback on the pure module (`Monty.Frameworks.Models.AbstractMontyClasses.SensorModule`).
  That split is what lets a sensor module be tested with a plain function call
  and still be supervised, restarted and inspected at runtime.

  The client API below is the only way in. It is deliberately separate from
  the callbacks, so call sites read as `SensorModuleServer.step(server, ...)`
  rather than as raw GenServer messages, and every entry point carries a
  typespec. The server registers itself in `Monty.Runtime.Registry` under
  `{:sensor_module, model_id, id}`: after a restart the name points at the new
  process and no stored pid goes stale.
  """

  use GenServer

  alias Monty.Cmp.{AttentionRegion, Goal, Message}
  alias Monty.Runtime.Registry

  @type id :: atom() | String.t()

  @type spec :: %{
          required(:id) => id(),
          required(:model_id) => id(),
          required(:module) => module(),
          required(:state) => term()
        }

  @type server :: GenServer.server()

  # -- client API -----------------------------------------------------------

  @spec start_link(spec()) :: GenServer.on_start()
  def start_link(%{id: id, model_id: model_id} = spec) do
    GenServer.start_link(__MODULE__, spec, name: Registry.via({:sensor_module, model_id, id}))
  end

  def child_spec(%{id: id, model_id: model_id} = spec) do
    %{
      id: {:sensor_module, model_id, id},
      start: {__MODULE__, :start_link, [spec]},
      restart: :permanent,
      type: :worker
    }
  end

  @doc """
  Records the sensor's pose and turns one observation into a percept.

  One round trip rather than two: `update_state` exists for the module's sake,
  not for the caller's.
  """
  @spec step(server(), map(), map(), Monty.Context.t(), boolean()) :: Message.t() | nil
  def step(server, observation, agent_state, ctx, motor_only? \\ false) do
    GenServer.call(server, {:step, observation, agent_state, ctx, motor_only?}, :infinity)
  end

  @spec propose_goals(server()) :: [Goal.t()]
  def propose_goals(server), do: GenServer.call(server, :propose_goals, :infinity)

  @spec propose_region(server()) :: AttentionRegion.t()
  def propose_region(server), do: GenServer.call(server, :propose_region, :infinity)

  @spec reset(server()) :: :ok
  def reset(server), do: GenServer.call(server, :reset, :infinity)

  @doc "The module's own state, for tests and the run inspector."
  @spec state(server()) :: term()
  def state(server), do: GenServer.call(server, :state, :infinity)

  # -- callbacks ------------------------------------------------------------

  @impl true
  def init(spec) do
    {:ok, %{module: spec.module, state: spec.state, id: spec.id}}
  end

  @impl true
  def handle_call({:step, observation, agent_state, ctx, motor_only?}, _from, server) do
    %{module: module, state: state} = server
    state = module.update_state(agent_state, state)
    {percept, state} = module.step(observation, motor_only?, ctx, state)

    {:reply, percept, %{server | state: state}}
  end

  def handle_call(:propose_goals, _from, server) do
    {goals, state} = server.module.propose_goals(server.state)
    {:reply, goals, %{server | state: state}}
  end

  def handle_call(:propose_region, _from, server) do
    {region, state} = server.module.propose_region(server.state)
    {:reply, region, %{server | state: state}}
  end

  def handle_call(:reset, _from, server) do
    {:reply, :ok, %{server | state: server.module.reset(server.state)}}
  end

  def handle_call(:state, _from, server), do: {:reply, server.state, server}
end
