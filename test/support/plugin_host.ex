defmodule MontyPlugin.Registry do
  @moduledoc false
  # Stands in for the plugin package on the far side of an `:rpc`.
  #
  # The studio reaches a plugin host by name — `Module.concat(["MontyPlugin",
  # "Registry"])` — because it does not depend on the package it talks to. That
  # is what makes the module name available to a test: a case can offer what a
  # host would offer and then read it back the way the studio reads it, without a
  # second VM and without linking the package in.
  #
  # `offer/3` takes the answer `lookup/2` gives: `{:ok, provider}` as a host's
  # registry answers it, or `{:error, why}` for a plugin it cannot use.

  @offers {__MODULE__, :offers}

  @doc "Offers `answer` for one kind and name, as `:pg` registration would."
  @spec offer(atom(), String.t(), term()) :: :ok
  def offer(kind, name, answer),
    do: :persistent_term.put(@offers, Map.put(offers(), {kind, name}, answer))

  @doc "Forgets every offer, so one case cannot see another's."
  @spec clear() :: :ok
  def clear, do: :persistent_term.put(@offers, %{})

  def lookup(kind, name), do: Map.get(offers(), {kind, name}, {:error, :not_offered})

  defp offers, do: :persistent_term.get(@offers, %{})
end

defmodule Monty.PluginHost.Provider do
  @moduledoc false
  # One plugin's process, as a host runs it: it answers `:describe` always, `:run`
  # when it was started with a definition — which is what an `:experiment` plugin
  # is asked for — and the four calls a motor policy is asked for. It keeps no
  # policy: the value it hands out at `{:new, []}` goes back with every call,
  # which is the only way one provider can serve two episodes at once.

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  # One child per plugin name: two policies on one host are two processes, and a
  # supervisor that gave both the module for an id would refuse the second.
  def child_spec(options) do
    %{
      id: {__MODULE__, Keyword.fetch!(options, :name)},
      start: {__MODULE__, :start_link, [options]}
    }
  end

  @impl true
  def init(options), do: {:ok, options}

  @impl true
  def handle_call(:describe, _from, options), do: {:reply, description(options), options}

  def handle_call(:run, _from, options) do
    case Keyword.fetch(options, :definition) do
      {:ok, definition} -> {:reply, {:ok, definition}, options}
      :error -> {:reply, {:error, "this plugin defines no run"}, options}
    end
  end

  def handle_call({:new, _options}, _from, options), do: {:reply, {:ok, 0}, options}

  def handle_call({:call, policy, _ctx, _observations, _state, _percept, goals}, _from, options) do
    result = %Monty.Frameworks.Models.MotorPolicies.MotorPolicyResult{
      actions: [{:step, policy, length(goals)}]
    }

    {:reply, {:ok, result, policy + 1}, options}
  end

  def handle_call({:reset, _policy}, _from, options), do: {:reply, {:ok, 0}, options}

  def handle_call({:state_dict, policy}, _from, options),
    do: {:reply, {:ok, %{steps: policy}}, options}

  defp description(options) do
    %{
      "name" => Keyword.fetch!(options, :name),
      "kind" => Keyword.get(options, :kind, :motor_policy),
      "version" => Keyword.get(options, :version, "0.1.1"),
      "placement" => :anywhere,
      "needs" => Keyword.get(options, :needs, [])
    }
  end
end
