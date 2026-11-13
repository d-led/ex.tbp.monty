defmodule Monty.Studio.RemotePolicy do
  @moduledoc """
  A motor policy that lives on another node: a plugin's, called once per step.

  `MontyPlugin` says a motor policy is called once per step, which is what makes
  calling one over a cluster free, and that the policy's state belongs where its
  plugin is. This is the studio's half of that agreement: a
  `MotorPolicySelector` whose policy is a process on the node offering it, and
  whose state is that process's — the policy struct never crosses, so a policy
  could in principle hold a part.

  ## Two questions, both the cluster's

  `configured/0` is this node's start-up decision, from `MONTY_REMOTE_POLICY`
  (12-factor, like every other choice a deployment makes). `find/1` is which
  node offers it: the peers whose tags say they host plugins — the same tags the
  Cluster page draws — are asked, and the first that answers with a usable
  description wins. A studio node is not asked, because it has no registry to
  answer from.

  Monty has no compile-time dependency on `ex_monty_plugin` here for the same
  reason `ExTbpMonty.Cluster.Nodes` has none: the question travels over `:rpc`,
  and a studio that linked the package to ask it would be a studio that has to be
  redeployed to talk to a plugin.

  ## What crosses

  The six arguments of a `call/6` and the result — context, observations, motor
  system state, percept, goals, and a `MotorPolicyResult`. Everything in them is
  a term, and both ends compile the same framework package, which is what the
  plugin's `version` is for: a policy and a caller built from different versions
  of the actions would answer with actions the caller cannot interpret.
  """

  @behaviour Monty.Frameworks.Models.MotorPolicySelectors.MotorPolicySelector

  alias ExTbpMonty.Cluster.Nodes
  alias Monty.Frameworks.Models.MotorPolicies.MotorPolicyResult
  alias Monty.Frameworks.Models.MotorPolicySelectors.MotorPolicySelector

  # Named as an atom rather than linked: see the moduledoc.
  @registry Module.concat(["MontyPlugin", "Registry"])
  @variable "MONTY_REMOTE_POLICY"
  @timeout 5_000

  @enforce_keys [:node, :name, :version, :pid]
  defstruct [:node, :name, :version, :pid]

  @typedoc "A policy resolved to the node that offers it, and the process that is it."
  @type t :: %__MODULE__{
          node: node(),
          name: String.t(),
          version: String.t(),
          pid: pid()
        }

  @doc """
  The policy this node was told to use, from `MONTY_REMOTE_POLICY`.

  `nil` is a node that runs its configs' own policies, which is every node that
  does not say otherwise.
  """
  @spec configured() :: String.t() | nil
  def configured do
    case System.get_env(@variable) do
      name when name in [nil, ""] -> nil
      name -> name
    end
  end

  @doc """
  The provider of `kind` and `name` on the peers that host plugins.

  A peer's answer is `MontyPlugin.Registry.lookup/2`'s: the pid to call, the
  node to call it on, and the description the plugin says about itself. A
  description the cluster cannot use is named as the reason rather than skipped:
  "offered but unusable" and "not offered" are different repairs.
  """
  @spec find(String.t(), atom()) :: {:ok, t()} | {:error, String.t()}
  def find(name, kind \\ :motor_policy) when is_binary(name), do: among(hosts(), name, kind)

  @doc """
  The provider of `name` among `hosts`, which is `find/2` with the asking left
  to the caller.

  Public because the asking is the part with a decision in it and the cluster is
  the part a test cannot have: a host is a map the poller wrote, and `:rpc` to a
  second VM is not something a case can arrange. The hosts part of `find/2`
  stays one line.
  """
  @spec among([map()], String.t(), atom()) :: {:ok, t()} | {:error, String.t()}
  def among([], name, _kind) do
    {:error,
     "no node in this cluster says it hosts plugins, so #{inspect(name)} cannot be " <>
       "reached: the node that offers it is not up, or not joined (`MONTY_SEEDS`)"}
  end

  def among(hosts, name, kind) do
    hosts
    |> Enum.reduce_while([], fn entry, asked ->
      case :rpc.call(entry.node, @registry, :lookup, [kind, name], @timeout) do
        {:ok, provider} -> {:halt, {:ok, of(provider)}}
        _not_there -> {:cont, [entry.name | asked]}
      end
    end)
    |> case do
      {:ok, policy} ->
        {:ok, policy}

      asked ->
        {:error,
         "#{inspect(name)} is offered by no node that hosts plugins; asked " <>
           Enum.map_join(Enum.reverse(asked), ", ", &inspect/1)}
    end
  end

  defp hosts do
    Enum.filter(Nodes.snapshot(), &ExTbpMonty.Cluster.Capabilities.plugin?/1)
  end

  defp of(%{node: node, name: name, pid: pid, describe: {:ok, describe}}) do
    %__MODULE__{node: node, name: name, version: version_of(describe), pid: pid}
  end

  defp of(%{name: name, describe: {:error, why}}) do
    raise ArgumentError,
          "the plugin #{inspect(name)} is offered but cannot be used: #{why}"
  end

  defp version_of(%{"version" => version}) when is_binary(version), do: version
  defp version_of(_unnamed), do: "unknown"

  @doc "What a run records about where its policy came from."
  @spec origin(t()) :: String.t()
  def origin(%__MODULE__{name: name, version: version, node: node}),
    do: "#{name}@#{version} on #{node}"

  @doc """
  The next action, chosen on the node that offers the policy.

  The selector comes back unchanged: nothing about the policy is remembered here,
  which is the point — a policy that holds a part holds it there.
  """
  @impl MotorPolicySelector
  @spec call(
          t(),
          Monty.Context.t(),
          map() | nil,
          Monty.Frameworks.Models.MotorSystemState.t(),
          Monty.Cmp.Message.t() | nil,
          [Monty.Cmp.Goal.t()]
        ) :: {MotorPolicyResult.t(), t()}
  def call(%__MODULE__{} = policy, ctx, observations, state, percept, goals) do
    case GenServer.call(policy.pid, {:call, ctx, observations, state, percept, goals}, @timeout) do
      {:ok, %MotorPolicyResult{} = result} -> {result, policy}
      {:error, why} -> raise ArgumentError, "#{policy.name} did not decide: #{why}"
      other -> raise ArgumentError, "#{policy.name} answered #{inspect(other)}"
    end
  catch
    :exit, reason ->
      raise ArgumentError,
            "the policy #{policy.name} on #{policy.node} stopped answering: #{inspect(reason)}"
  end

  @doc "Starts the next episode on the plugin's side: its state, its reset."
  @impl MotorPolicySelector
  def reset(%__MODULE__{} = policy) do
    GenServer.call(policy.pid, :reset, @timeout)
    policy
  catch
    :exit, reason ->
      raise ArgumentError,
            "the policy #{policy.name} on #{policy.node} could not be reset: #{inspect(reason)}"
  end

  @doc "What the policy recorded, read from where it recorded it."
  @impl MotorPolicySelector
  def state_dict(%__MODULE__{} = policy) do
    recorded = GenServer.call(policy.pid, :state_dict, @timeout)
    Map.merge(%{policy: policy.name, version: policy.version, node: policy.node}, recorded)
  catch
    :exit, reason ->
      raise ArgumentError,
            "the policy #{policy.name} on #{policy.node} could not report: #{inspect(reason)}"
  end
end
