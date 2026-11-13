defmodule ExamplePlugin.Offer do
  @moduledoc """
  The process one plugin is, and the one answer the contract asks of it.

  `MontyPlugin.Registry` reaches a plugin by `:pg` and asks it `:describe`; a
  motor policy is also *called*, once per step, from whichever node is running
  the experiment (`MontyPlugin` on kinds). So this process is both: the
  description a cluster asks for, and — for a plugin that has a decision in it —
  the place that decision is made.

  ## Nothing here is remembered between two calls

  This process is one per kind and name for the whole cluster, and a cluster runs
  several episodes at once: the six parts of a sweep are six episodes in one VM.
  A policy kept here would be one policy shared by all of them, and this plugin's
  first parallel sweep made that concrete — six parts lost to a single pre-jump
  pose they had overwritten for each other.

  So the policy is an argument. It is built once (`{:new, options}`), it goes out
  with every step and comes back changed, and it is what a caller holds. The state
  a policy keeps is the caller's, which is what makes two episodes two policies.

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

      {:ok, %{plugin: plugin}}
    else
      {:error, reason} -> {:stop, "#{inspect(plugin)} cannot be offered: #{reason}"}
    end
  end

  @impl true
  def handle_call(:describe, _from, %{plugin: plugin} = offer),
    do: {:reply, plugin.describe(), offer}

  # An experiment is the definition of a run rather than a step of one, so it is
  # asked once, and what comes back is data: the config's name and the modules the
  # run wants.
  def handle_call(:run, _from, %{plugin: plugin} = offer) do
    if function_exported?(plugin, :run, 0) do
      {:reply, {:ok, plugin.run()}, offer}
    else
      {:reply, {:error, "#{inspect(plugin)} defines no run and cannot be started"}, offer}
    end
  end

  # A policy's first value is what its own constructor makes, and the caller keeps
  # it: what an episode starts from is decided once, here, and then travels.
  def handle_call({:new, options}, _from, %{plugin: plugin} = offer) do
    if function_exported?(plugin, :new, 1) do
      {:reply, {:ok, plugin.new(options)}, offer}
    else
      {:reply, {:error, "#{inspect(plugin)} is not a motor policy and has no first policy"},
       offer}
    end
  end

  # A motor policy is called once per step with the framework's six arguments,
  # the policy among them, and answers the result and the policy as it now stands.
  def handle_call(
        {:call, policy, ctx, observations, state, percept, goals},
        _from,
        %{plugin: plugin} = offer
      ) do
    if function_exported?(plugin, :call, 6) do
      {result, policy} = plugin.call(policy, ctx, observations, state, percept, List.first(goals))

      {:reply, {:ok, result, policy}, offer}
    else
      {:reply, {:error, "#{inspect(plugin)} is not a motor policy and decides nothing"}, offer}
    end
  end

  def handle_call({:reset, policy}, _from, %{plugin: plugin} = offer) do
    if function_exported?(plugin, :reset, 1) do
      {:reply, {:ok, plugin.reset(policy)}, offer}
    else
      {:reply, {:error, "#{inspect(plugin)} is not a motor policy and has nothing to reset"},
       offer}
    end
  end

  def handle_call({:state_dict, policy}, _from, %{plugin: plugin} = offer) do
    recorded =
      if function_exported?(plugin, :state_dict, 1), do: plugin.state_dict(policy), else: %{}

    {:reply, {:ok, recorded}, offer}
  end
end
