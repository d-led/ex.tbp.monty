defmodule ExamplePlugin.Offer do
  @moduledoc """
  The process one plugin is, and the one answer the contract asks of it.

  `MontyPlugin.Registry` reaches a plugin by `:pg` and then asks it one question
  — `:describe` — so a plugin with nothing to keep between calls is still a
  process, and this is its whole body. The description is checked **at boot**:
  a plugin that names itself unusably stops the application instead of being
  offered as though it were a choice, which is the difference between a failed
  start and a cluster that lists something nobody can call.

  Nothing here knows which plugin it holds: the module is the state, and
  `describe/0` is the only thing it has to define. A plugin with work to do
  beside its description keeps that work in its own process and hands this one
  the description to answer with.
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

      {:ok, plugin}
    else
      {:error, reason} -> {:stop, "#{inspect(plugin)} cannot be offered: #{reason}"}
    end
  end

  @impl true
  def handle_call(:describe, _from, plugin), do: {:reply, plugin.describe(), plugin}
end
