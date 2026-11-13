defmodule FlyversePlugin.Offer do
  @moduledoc """
  The process one plugin is, and the four answers the contract asks of it.

  `MontyPlugin.Registry` reaches a plugin by `:pg` and asks it `:describe`; a
  motor policy is also *called*, once per step, from whichever node is running
  the experiment. So this process is both the description a cluster asks for and
  the place the decision is made — which for this plugin is not a small matter,
  because the decision is a simulation.

  ## The simulation is here, and that is the point

  A NIF resource cannot be sent to another node, so a policy that stepped one
  cannot carry it. What crosses with every call is the policy value — the name of
  a simulation, and the numbers that shape its turn — and what stays here is the
  membrane potential of every neuron in the pack. That is what `:owner_only`
  means, and this plugin is the example of it: `RemotePolicy` may call this
  process from anywhere in the cluster, and only the node this process runs on
  can answer.

  ## A plugin that cannot be offered stops the application

  The description is checked at boot (`MontyPlugin.conforms?/1`), and a plugin
  that names itself unusably is a plugin nobody should be offered. The name is
  cluster-wide — `:pg` groups by kind and name — so the two here carry the host
  that owns them: `flyverse_plugin.lif_steering` and
  `flyverse_plugin.10simobj_surf_agent`.
  """

  use GenServer

  require Logger

  @doc false
  def child_spec(plugin) when is_atom(plugin) do
    %{id: plugin, start: {__MODULE__, :start_link, [plugin]}}
  end

  @doc false
  def start_link(plugin), do: GenServer.start_link(__MODULE__, plugin)

  @impl true
  def init(plugin) do
    description = plugin.describe()

    with :ok <- MontyPlugin.conforms?(description),
         :ok <- MontyPlugin.Registry.register(description["kind"], description["name"], self()) do
      Logger.info(
        "flyverse plugin: offering #{description["kind"]} #{description["name"]} " <>
          "#{description["version"]} (#{description["placement"]})"
      )

      {:ok, %{plugin: plugin, state: plugin.initial_state()}}
    else
      {:error, reason} -> {:stop, "#{inspect(plugin)} cannot be offered: #{reason}"}
    end
  end

  @impl true
  def handle_call(:describe, _from, %{plugin: plugin} = offer),
    do: {:reply, plugin.describe(), offer}

  # An experiment is the definition of a run rather than a step of one, so it is
  # asked once, and what comes back is data: the config's name and the modules
  # the run wants.
  def handle_call(:run, _from, %{plugin: plugin} = offer) do
    if function_exported?(plugin, :run, 0) do
      {:reply, {:ok, plugin.run()}, offer}
    else
      {:reply, {:error, "#{inspect(plugin)} defines no run and cannot be started"}, offer}
    end
  end

  # A policy's first value is what its own constructor makes, plus whatever the
  # construction had to open — this plugin's simulation. The caller keeps the
  # value; the process keeps the state.
  def handle_call({:new, options}, _from, %{plugin: plugin, state: state} = offer) do
    if function_exported?(plugin, :new, 2) do
      case plugin.new(options, state) do
        {:ok, policy, state} -> {:reply, {:ok, policy}, %{offer | state: state}}
        {:error, why} -> {:reply, {:error, why}, offer}
      end
    else
      {:reply, {:error, "#{inspect(plugin)} is not a motor policy and has no first policy"},
       offer}
    end
  end

  # A motor policy is called once per step with the framework's six arguments,
  # the policy among them, and answers the result and the policy as it now
  # stands. `goals` is a list in the framework's shape; a policy decides for one
  # goal, which is what `List.first/1` is.
  def handle_call(
        {:call, policy, ctx, observations, motor_state, percept, goals},
        _from,
        %{plugin: plugin, state: state} = offer
      ) do
    if function_exported?(plugin, :call, 3) do
      case plugin.call(
             policy,
             {ctx, observations, motor_state, percept, List.first(goals)},
             state
           ) do
        {:ok, result, policy, state} -> {:reply, {:ok, result, policy}, %{offer | state: state}}
        {:error, why} -> {:reply, {:error, why}, offer}
      end
    else
      {:reply, {:error, "#{inspect(plugin)} is not a motor policy and decides nothing"}, offer}
    end
  end

  def handle_call({:reset, policy}, _from, %{plugin: plugin, state: state} = offer) do
    if function_exported?(plugin, :reset, 2) do
      case plugin.reset(policy, state) do
        {:ok, policy, state} -> {:reply, {:ok, policy}, %{offer | state: state}}
        {:error, why} -> {:reply, {:error, why}, offer}
      end
    else
      {:reply, {:error, "#{inspect(plugin)} is not a motor policy and has nothing to reset"},
       offer}
    end
  end

  def handle_call({:state_dict, policy}, _from, %{plugin: plugin, state: state} = offer) do
    recorded =
      if function_exported?(plugin, :state_dict, 2),
        do: plugin.state_dict(policy, state),
        else: %{}

    {:reply, {:ok, recorded}, offer}
  end
end
