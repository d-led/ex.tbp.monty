defmodule ExamplePlugin.Offer do
  @moduledoc """
  The process one plugin is, and the one answer the contract asks of it.

  `MontyPlugin.Registry` reaches a plugin by `:pg` and asks it `:describe`; a
  motor policy is also *called*, once per step, from whichever node is running
  the experiment (`MontyPlugin` on kinds). So this process is both: the
  description a cluster asks for, and — for a plugin that has a decision in it —
  the place that decision lives.

  That is the whole reason a policy is a process rather than a module the caller
  compiles in: the state belongs here. A policy that remembers where it was being
  walked remembers it on the plugin's node, and the caller holds a pid.

  The description is checked **at boot**: a plugin that names itself unusably
  stops the application instead of being offered as though it were a choice.
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
        "example plugin: offering #{description["kind"]} #{description["name"]} " <>
          "#{description["version"]} (#{description["placement"]})"
      )

      {:ok, %{plugin: plugin, state: initial_state(plugin)}}
    else
      {:error, reason} -> {:stop, "#{inspect(plugin)} cannot be offered: #{reason}"}
    end
  end

  @impl true
  def handle_call(:describe, _from, %{plugin: plugin} = offer),
    do: {:reply, plugin.describe(), offer}

  # An experiment is the definition of a run rather than a step of one, so it is
  # asked once, and what comes back is data: the config's name and the modules the
  # run wants. Nothing is remembered here — a definition that changed between two
  # reads would be a run that is not the one the record names.
  def handle_call(:run, _from, %{plugin: plugin} = offer) do
    if function_exported?(plugin, :run, 0) do
      {:reply, {:ok, plugin.run()}, offer}
    else
      {:reply, {:error, "#{inspect(plugin)} defines no run and cannot be started"}, offer}
    end
  end

  # A motor policy is called once per step with the framework's six arguments and
  # answers the result and itself. The result crosses the cluster; the policy does
  # not — it is this process's state, which is why the next step starts from where
  # the last one stopped.
  def handle_call(
        {:call, ctx, observations, state, percept, goals},
        _from,
        %{plugin: plugin} = offer
      ) do
    if function_exported?(plugin, :call, 6) do
      {result, policy} =
        plugin.call(offer.state, ctx, observations, state, percept, List.first(goals))

      {:reply, {:ok, result}, %{offer | state: policy}}
    else
      {:reply, {:error, "#{inspect(plugin)} is not a motor policy and decides nothing"}, offer}
    end
  end

  def handle_call(:reset, _from, %{plugin: plugin} = offer),
    do: {:reply, :ok, %{offer | state: initial_state(plugin)}}

  def handle_call(:state_dict, _from, %{plugin: plugin} = offer) do
    recorded =
      if function_exported?(plugin, :state_dict, 1), do: plugin.state_dict(offer.state), else: %{}

    {:reply, recorded, offer}
  end

  # A policy's first state is what its own constructor makes. A plugin of another
  # kind keeps nothing between calls, so there is nothing to build.
  defp initial_state(plugin) do
    if function_exported?(plugin, :new, 0), do: plugin.new(), else: nil
  end
end
