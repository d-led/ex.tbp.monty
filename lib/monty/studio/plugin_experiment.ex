defmodule Monty.Studio.PluginExperiment do
  @moduledoc """
  A run a plugin defines, opened the way `Monty.Studio.open/2` opens one of ours.

  An `:experiment` plugin answers one question — `run/0` — and what it says is
  data: the config to step and the modules the run wants for it. This module is
  the caller's side of that: it asks the plugin, composes the config it names,
  and resolves the modules it asks for **against what this cluster can actually
  serve**. A definition naming something no node can serve is refused here, with
  the sentence that says so, rather than failing at the first step of a run that
  looked startable.

  ## What it can serve, today

  A **motor policy** is called once per step, so a plugin's policy is used as the
  run's motor system (`Monty.Studio.RemotePolicy`). A **learning module** is
  advertised rather than routed — a step asks it thousands of times over
  hypotheses and a k-d tree, so the node that runs has to have its code — and a
  definition that names one is refused by name. `docs/plugins.md` keeps the score;
  when learning modules are routed, this is the module that stops refusing them.

  ## The node's own policy does not apply

  A studio node may have been started with `MONTY_REMOTE_POLICY`, which decides
  the policy of *our* configs. A plugin's experiment says what runs it, so its
  definition decides, and a definition naming no motor system means the config's
  own one — not this node's environment.
  """

  alias Monty.Studio.{Diagram, RemotePolicy, Setup}

  # The kind this module asks for, and the request a definition is read with.
  @kind :experiment
  @read_definition :run
  @timeout 5_000

  @doc """
  Opens the experiment `name` offers, or says why it cannot be started.

  Options are `open/2`'s — `:world_simulator` and `:pretrained_dir` — and
  `:hosts`, which is the nodes to ask. The cluster is the default; a case that
  offers a plugin from a process of its own names the host instead of running
  one.
  """
  @spec open(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def open(name, opts \\ []) when is_binary(name) do
    hosts = Keyword.get_lazy(opts, :hosts, &hosts/0)

    with {:ok, provider} <- provider(name, hosts),
         {:ok, definition} <- definition(name, provider),
         {:ok, tree} <- base(name, definition),
         :ok <- servable(name, definition),
         {:ok, policy} <- motor(name, definition, hosts) do
      {:ok, opened(name, tree, definition, provider, policy, opts)}
    end
  end

  # The peers whose tags say they host plugins — the same question
  # `Monty.Studio.RemotePolicy` asks, and the same answer: a studio node has no
  # registry to answer from, so it is not one of them.
  defp hosts do
    Enum.filter(ExTbpMonty.Cluster.Nodes.snapshot(), &ExTbpMonty.Cluster.Capabilities.plugin?/1)
  end

  defp provider(name, hosts) do
    case RemotePolicy.among(hosts, name, @kind) do
      {:ok, provider} ->
        {:ok, provider}

      {:error, why} ->
        {:error, "no experiment here is named #{inspect(name)}, and #{why}"}
    end
  end

  # Asked once, because that is what a definition is: a definition that changed
  # between two reads would be a run that is not the one the record names.
  defp definition(name, %RemotePolicy{pid: pid}) do
    case GenServer.call(pid, @read_definition, @timeout) do
      {:ok, %{} = definition} -> {:ok, definition}
      {:error, why} -> {:error, "the experiment #{inspect(name)} cannot be read: #{why}"}
      other -> {:error, "the experiment #{inspect(name)} answered #{inspect(other)}"}
    end
  catch
    :exit, reason ->
      {:error, "the experiment #{inspect(name)} stopped answering: #{inspect(reason)}"}
  end

  defp base(name, %{"base" => base}) when is_binary(base) do
    case Monty.Config.Composer.compose(base) do
      {:ok, tree} ->
        {:ok, tree}

      {:error, why} ->
        {:error,
         "the experiment #{inspect(name)} steps the config #{inspect(base)}, " <>
           "which this node cannot compose: #{inspect(why)}"}
    end
  end

  defp base(name, _definition) do
    {:error, "the experiment #{inspect(name)} names no base config, so there is nothing to step"}
  end

  # A module a run asks for has to be reachable from the node that would step it.
  # The motor system is checked by being resolved (below), and the learning
  # modules are the kind that cannot be: say which one, and why.
  defp servable(name, %{"learning_modules" => [module | _rest]}) do
    {:error,
     "the experiment #{inspect(name)} asks for the learning module #{inspect(module)}, and a " <>
       "learning module is advertised rather than routed: a step asks it thousands of times, " <>
       "so the node that runs must have its code, which it has only for its own " <>
       "(`docs/plugins.md`)"}
  end

  defp servable(_name, _definition), do: :ok

  defp motor(name, %{"motor_system" => motor}, hosts) when is_binary(motor) do
    with {:ok, found} <- RemotePolicy.among(hosts, motor, :motor_policy),
         {:ok, started} <- RemotePolicy.start(found) do
      {:ok, started}
    else
      {:error, why} -> {:error, "the experiment #{inspect(name)} names a motor system: #{why}"}
    end
  end

  defp motor(_name, _definition, _hosts), do: {:ok, nil}

  # The seed a definition names is the seed the run uses. A definition that said
  # `seed: 42` and then ran under the base config's own seed would be a record
  # that disagrees with the thing it came from, and two runs of one experiment
  # would differ for a reason nobody wrote down.
  defp seeded(tree, %{"seed" => seed}) when is_integer(seed) do
    if get_in(tree, ["experiment", "config"]) == nil do
      tree
    else
      put_in(tree, ["experiment", "config", "seed"], seed)
    end
  end

  defp seeded(tree, _definition), do: tree

  defp opened(name, tree, definition, provider, policy, opts) do
    setup =
      Setup.new(
        seeded(tree, definition),
        [name: name, remote_policy: policy && {:ok, policy}] ++
          Keyword.take(opts, [:world_simulator, :pretrained_dir])
      )

    %{
      name: name,
      source: :plugin,
      setup: setup,
      diagram: Diagram.new(setup),
      yaml: nil,
      groups: %{},
      config: tree,
      plugin: %{
        node: provider.node,
        name: provider.name,
        version: provider.version,
        definition: definition
      }
    }
  end
end
