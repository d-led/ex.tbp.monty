defmodule Monty.Runtime.SensorModuleServer do
  @moduledoc """
  One sensor module, one process.

  The process holds the module's state and nothing else: every decision is a
  callback on the pure module (`Monty.Frameworks.Models.AbstractMontyClasses.SensorModule`).
  That split is what lets a sensor module be tested with a plain function call
  and still be supervised, restarted and inspected at runtime.

  The server registers itself in `Monty.Runtime.Registry` under
  `{:sensor_module, id}`, so the coordinator addresses it through a `:via`
  tuple: after a restart the name points at the new process and no stored pid
  goes stale.
  """

  use GenServer

  alias Monty.Runtime.Registry

  @type spec :: %{
          required(:id) => atom() | String.t(),
          required(:model_id) => atom() | String.t(),
          required(:module) => module(),
          required(:state) => term()
        }

  @doc "Starts a sensor module process for one module and its initial state."
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

  @impl true
  def init(spec) do
    {:ok, %{module: spec.module, state: spec.state, id: spec.id}}
  end

  @impl true
  def handle_call({:step, observation, agent_state, motor_only?}, _from, server) do
    %{module: module, state: state} = server
    state = module.update_state(agent_state, state)
    {percept, state} = module.step(observation, motor_only?, state)

    {:reply, percept, %{server | state: state}}
  end

  def handle_call(:propose_goals, _from, %{module: module, state: state} = server) do
    {goals, state} = optional(module, :propose_goals, state, [])
    {:reply, goals, %{server | state: state}}
  end

  def handle_call(:propose_region, _from, %{module: module, state: state} = server) do
    {region, state} = optional(module, :propose_region, state, Monty.Cmp.AttentionRegion.empty())
    {:reply, region, %{server | state: state}}
  end

  def handle_call(:reset, _from, %{module: module, state: state} = server) do
    {:reply, :ok, %{server | state: module.reset(state)}}
  end

  def handle_call(:state, _from, server), do: {:reply, server.state, server}

  defp optional(module, function, state, default) do
    if function_exported?(module, function, 1),
      do: apply(module, function, [state]),
      else: {default, state}
  end
end
