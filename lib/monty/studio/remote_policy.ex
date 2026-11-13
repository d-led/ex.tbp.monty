defmodule Monty.Studio.RemotePolicy do
  @moduledoc """
  A motor policy that lives on another node: a plugin's, called once per step.

  `MontyPlugin` says a motor policy is called once per step, which is what makes
  calling one over a cluster free. This is the studio's half of that agreement: a
  `MotorPolicySelector` whose policy is decided on the node offering it.

  ## The policy is a value, and it crosses

  A plugin is one process per kind and name for the whole cluster, and a cluster
  runs several episodes at once: the six parts of one sweep are six episodes in
  one VM. A provider that kept "the policy" as its own state would be one policy
  shared by every episode running anywhere — and a policy is not a thing to share.
  The first parallel sweep this studio ran with a plugin's surface policy lost all
  six parts to one pre-jump pose that they had overwritten for each other, each
  asserting it had been put back where another part had moved it.

  So the policy travels. This struct carries it, every call carries it, and the
  provider is a function of what it was handed:

      {:new, options}                                  => {:ok, policy}
      {:call, policy, ctx, observations, state, p, g}  => {:ok, result, policy}
      {:reset, policy}                                 => {:ok, policy}
      {:state_dict, policy}                            => {:ok, recorded}

  which is `MotorPolicy`'s own shape — the argument in, the argument out — with
  the policy named first so that nothing about it is remembered where it is
  decided. Two episodes cannot meet, and a batch cannot share a heading by
  accident.

  What that costs is copying the policy once per step, a few hundred numbers
  beside the depth images in `observations` on the same call.

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

  The call's six arguments and the answer — context, observations, motor system
  state, percept, goals, and a `MotorPolicyResult` — and the policy itself, in
  both directions. Everything in them is a term, and both ends compile the same
  framework package, which is what the plugin's `version` is for: a policy and a
  caller built from different versions of the actions would answer with actions
  the caller cannot interpret.
  """

  @behaviour Monty.Frameworks.Models.MotorPolicySelectors.MotorPolicySelector

  alias ExTbpMonty.Cluster.Capabilities
  alias ExTbpMonty.Cluster.Nodes
  alias Monty.Frameworks.Models.MotorPolicies.MotorPolicyResult
  alias Monty.Frameworks.Models.MotorPolicySelectors.MotorPolicySelector
  alias Monty.Studio.Failure

  # Named as an atom rather than linked: see the moduledoc.
  @registry Module.concat(["MontyPlugin", "Registry"])
  @variable "MONTY_REMOTE_POLICY"
  @timeout 5_000

  @enforce_keys [:node, :name, :version, :pid]
  defstruct [:node, :name, :version, :pid, :policy]

  @typedoc """
  A policy resolved to the node that offers it, the process that decides it, and
  the policy itself — the value every call carries, `nil` until `among/3` starts
  one.
  """
  @type t :: %__MODULE__{
          node: node(),
          name: String.t(),
          version: String.t(),
          pid: pid(),
          policy: term()
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
  def find(name, kind \\ :motor_policy) when is_binary(name),
    do: with({:ok, remote} <- among(hosts(), name, kind), do: start(remote))

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
    answers = Enum.map(hosts, &ask(&1, name, kind))
    offerings = for {:offered, host, provider} <- answers, do: offering(host, provider)

    case Enum.filter(offerings, &(&1.missing == [])) do
      [fit | _] -> {:ok, fit.policy}
      [] -> {:error, refusal(answers, offerings, name)}
    end
  end

  @doc """
  The provider, and the policy a run starts from.

  Separate from `among/3` because finding a provider and being able to start a
  policy on it are two questions, and only a motor policy has a second answer: an
  experiment plugin is found the same way and starts nothing.

  The options are empty because there is nobody to take them from: a config's
  policy numbers belong to the policy the config names, and a run that asked for a
  plugin's policy asked for the plugin's own decisions, which its `new/1` is where
  to read.

  Public for the reason `among/3` is: the start is a call to another process, which
  a case can have and a cluster cannot.
  """
  @spec start(t()) :: {:ok, t()} | {:error, String.t()}
  def start(%__MODULE__{policy: nil} = remote) do
    case GenServer.call(remote.pid, {:new, []}, @timeout) do
      {:ok, policy} -> {:ok, %{remote | policy: policy}}
      {:error, why} -> {:error, "#{remote.name} on #{remote.node} could not be built: #{why}"}
      other -> {:error, "#{remote.name} on #{remote.node} answered #{Failure.reply(other)}"}
    end
  catch
    :exit, reason ->
      {:error,
       "the policy #{remote.name} on #{remote.node} stopped answering: #{Failure.lost(reason)}"}
  end

  def start(%__MODULE__{} = already_started), do: {:ok, already_started}

  # Every host is asked, and the answer is kept with the host it came from: which
  # node offers a plugin and whether that node can serve it are two facts, and a
  # caller that stopped at the first answer would be handed the second-best one
  # without knowing there was a better.
  defp ask(host, name, kind) do
    case :rpc.call(host.node, @registry, :lookup, [kind, name], @timeout) do
      {:ok, provider} -> {:offered, host, provider}
      _not_there -> {:not_offered, host}
    end
  end

  # What an offering is worth. A plugin says what it needs to answer at all
  # (`MontyPlugin`'s `needs`: the geometry, the file, the framework), and a node
  # that offers the plugin without offering one of them is a node where the call
  # fails inside the plugin, at a step, where the cluster cannot predict it — so
  # it is not a candidate, and `refusal/3` says what it lacks rather than leaving
  # a reader to guess.
  defp offering(host, provider), do: %{policy: of(provider), missing: lacking(host, provider)}

  defp lacking(host, %{describe: {:ok, describe}}) do
    describe
    |> Map.get("needs", [])
    |> Enum.reject(&Capabilities.offers?(host.capabilities, &1))
  end

  defp refusal(answers, [], name) do
    "#{inspect(name)} is offered by no node that hosts plugins; asked " <>
      Enum.map_join(answers, ", ", fn {_answer, host} -> inspect(host.name) end)
  end

  defp refusal(_answers, offerings, name) do
    "#{inspect(name)} is offered, but by no node that can serve it: " <>
      Enum.map_join(offerings, "; ", fn offering ->
        "#{offering.policy.name} on #{offering.policy.node} does not offer " <>
          Enum.map_join(offering.missing, ", ", &inspect/1)
      end)
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

  The policy goes with the call and comes back changed, which is the whole of
  what a step remembers: this struct is the only copy, so two episodes stepping
  at once hold two policies and neither can see the other's.
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
  def call(%__MODULE__{} = remote, ctx, observations, state, percept, goals) do
    call_args = {:call, remote.policy, ctx, observations, state, percept, goals}

    case GenServer.call(remote.pid, call_args, @timeout) do
      {:ok, %MotorPolicyResult{} = result, policy} -> {result, %{remote | policy: policy}}
      {:error, why} -> raise ArgumentError, "#{remote.name} did not decide: #{why}"
      other -> raise ArgumentError, "#{remote.name} answered #{Failure.reply(other)}"
    end
  catch
    :exit, reason ->
      raise ArgumentError,
            "the policy #{remote.name} on #{remote.node} stopped answering: #{Failure.lost(reason)}"
  end

  @doc "Starts the next episode on the plugin's side: its policy, reset."
  @impl MotorPolicySelector
  def reset(%__MODULE__{} = remote) do
    case GenServer.call(remote.pid, {:reset, remote.policy}, @timeout) do
      {:ok, policy} -> %{remote | policy: policy}
      {:error, why} -> raise ArgumentError, "#{remote.name} could not be reset: #{why}"
      other -> raise ArgumentError, "#{remote.name} answered #{Failure.reply(other)}"
    end
  catch
    :exit, reason ->
      raise ArgumentError,
            "the policy #{remote.name} on #{remote.node} could not be reset: #{Failure.lost(reason)}"
  end

  @doc "What the policy the run holds recorded."
  @impl MotorPolicySelector
  def state_dict(%__MODULE__{} = remote) do
    recorded =
      case GenServer.call(remote.pid, {:state_dict, remote.policy}, @timeout) do
        {:ok, recorded} -> recorded
        {:error, why} -> raise ArgumentError, "#{remote.name} could not report: #{why}"
        other -> raise ArgumentError, "#{remote.name} answered #{Failure.reply(other)}"
      end

    Map.merge(%{policy: remote.name, version: remote.version, node: remote.node}, recorded)
  catch
    :exit, reason ->
      raise ArgumentError,
            "the policy #{remote.name} on #{remote.node} could not report: #{Failure.lost(reason)}"
  end
end
