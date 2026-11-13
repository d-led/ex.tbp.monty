defmodule Monty.Studio.RemotePolicyTest do
  @moduledoc """
  What a policy on another node owes a step, and what the studio owes it back.

  The policy travels: the provider is a function of what it was handed, so the
  cases here are about that seam — a step is decided by the process, the policy
  comes back changed, and a policy that has gone away says so rather than
  producing a step nobody decided. Two episodes stepping at once is the case this
  convention exists for: the provider is one process for the whole cluster, so a
  provider that remembered would be one policy shared by every episode running.

  Not async: a node's environment and the stand-in's table are the node's, and one
  case here sets what the node was told to run.
  """

  use ExUnit.Case, async: false

  alias Monty.Frameworks.Models.MotorPolicies.MotorPolicyResult
  alias Monty.Studio.RemotePolicy

  # A policy that counts its own steps, so a case can say which of two policies a
  # step advanced. A counter is the smallest thing that can be shared by accident.
  defmodule Provider do
    @moduledoc false
    use GenServer

    def start_link(calls), do: GenServer.start_link(__MODULE__, calls)

    @impl true
    def init(calls), do: {:ok, calls}

    @impl true
    def handle_call({:new, _options}, _from, calls), do: {:reply, {:ok, 0}, calls}

    def handle_call({:call, policy, _ctx, _observations, _state, _percept, goals}, _from, calls) do
      result = %MotorPolicyResult{actions: [{:step, policy, length(goals)}]}
      {:reply, {:ok, result, policy + 1}, calls + 1}
    end

    def handle_call({:reset, _policy}, _from, calls), do: {:reply, {:ok, 0}, calls}

    def handle_call({:state_dict, policy}, _from, calls),
      do: {:reply, {:ok, %{steps: policy}}, calls}
  end

  setup do
    provider = start_supervised!({Provider, 0})
    previous = System.get_env("MONTY_REMOTE_POLICY")
    System.delete_env("MONTY_REMOTE_POLICY")
    MontyPlugin.Registry.clear()

    on_exit(fn ->
      restore(previous)
      MontyPlugin.Registry.clear()
    end)

    %{
      policy: started(provider),
      provider: provider
    }
  end

  test "a step is decided by the process that offers the policy", %{policy: policy} do
    assert {%MotorPolicyResult{actions: [{:step, 0, 1}]}, %RemotePolicy{policy: 1}} =
             RemotePolicy.call(policy, %{}, nil, %{}, nil, [%{}])
  end

  test "the policy comes back changed, and that is where the next step starts", %{
    policy: policy
  } do
    {_first, policy} = RemotePolicy.call(policy, %{}, nil, %{}, nil, [])
    {_second, policy} = RemotePolicy.call(policy, %{}, nil, %{}, nil, [])

    assert RemotePolicy.state_dict(policy) == %{
             steps: 2,
             policy: "example_scan",
             version: "0.1.0",
             node: node()
           }
  end

  # The case the convention exists for. One provider is one process for the whole
  # cluster, and a sweep is several episodes in it: a policy kept in that process
  # would be one heading walked by every part at once.
  test "two episodes hold two policies and neither advances the other", %{policy: policy} do
    {_mine, mine} = RemotePolicy.call(policy, %{}, nil, %{}, nil, [])
    {_mine, mine} = RemotePolicy.call(mine, %{}, nil, %{}, nil, [])
    {theirs, other} = RemotePolicy.call(policy, %{}, nil, %{}, nil, [])

    assert {%MotorPolicyResult{actions: [{:step, 2, 0}]}, _mine} =
             RemotePolicy.call(mine, %{}, nil, %{}, nil, [])

    assert %MotorPolicyResult{actions: [{:step, 0, 0}]} = theirs
    assert %RemotePolicy{policy: 1} = other
  end

  test "starting an episode reaches the node that owns the state", %{policy: policy} do
    {_first, policy} = RemotePolicy.call(policy, %{}, nil, %{}, nil, [])

    assert %RemotePolicy{policy: 0} = RemotePolicy.reset(policy)
  end

  test "a policy whose node has gone says which policy stopped answering", %{policy: policy} do
    stop_supervised!(Provider)

    assert_raise ArgumentError,
                 ~r/example_scan on #{Regex.escape(to_string(node()))} stopped answering/,
                 fn ->
                   RemotePolicy.call(policy, %{}, nil, %{}, nil, [])
                 end
  end

  # A run's page shows the sentence its failure left, so the sentence is a reason
  # and not the request that was being made: a `:call` exit holds the policy and
  # the observations it was deciding on, and a reader of a run is not debugging
  # Elixir.
  test "a policy that stopped answering says why in words, not in terms", %{policy: policy} do
    stop_supervised!(Provider)

    exception =
      assert_raise ArgumentError, fn -> RemotePolicy.call(policy, %{}, nil, %{}, nil, []) end

    message = Exception.message(exception)

    assert message =~ "its process is gone"
    refute message =~ "GenServer"
    refute message =~ "#PID"
    refute message =~ "RemotePolicy"
  end

  test "a policy nobody is left to start says why in words", %{policy: policy} do
    stop_supervised!(Provider)

    assert {:error, sentence} = RemotePolicy.start(%{policy | policy: nil})
    assert sentence =~ "stopped answering: its process is gone"
  end

  test "a run records where its policy came from", %{policy: policy} do
    assert RemotePolicy.origin(policy) == "example_scan@0.1.0 on #{node()}"
  end

  test "a node that was told nothing runs its configs' own policies" do
    assert RemotePolicy.configured() == nil

    System.put_env("MONTY_REMOTE_POLICY", "example_scan")
    assert RemotePolicy.configured() == "example_scan"
  end

  describe "finding the policy" do
    test "the host that offers it is the one that is used", %{provider: provider} do
      MontyPlugin.Registry.offer(:motor_policy, "example_scan", {:ok, offering(provider)})

      assert RemotePolicy.among([here()], "example_scan", :motor_policy) ==
               {:ok,
                %RemotePolicy{
                  node: node(),
                  name: "example_scan",
                  version: "0.2.0",
                  pid: provider,
                  policy: nil
                }}
    end

    # Found and started are two questions, and only a policy has the second: a
    # plugin that defines an experiment is found here and starts nothing.
    test "a provider is not a policy until the plugin is asked for one", %{provider: provider} do
      MontyPlugin.Registry.offer(:motor_policy, "example_scan", {:ok, offering(provider)})

      assert {:ok, found} = RemotePolicy.among([here()], "example_scan", :motor_policy)
      assert found.policy == nil
      assert {:ok, %RemotePolicy{policy: 0}} = RemotePolicy.start(found)
    end

    test "a host that does not answer is passed over for one that does", %{provider: provider} do
      MontyPlugin.Registry.offer(:motor_policy, "example_scan", {:ok, offering(provider)})
      here = node()

      assert {:ok, %RemotePolicy{node: ^here}} =
               RemotePolicy.among(
                 [host(:"gone@127.0.0.1"), here()],
                 "example_scan",
                 :motor_policy
               )
    end

    test "a policy no host offers names the hosts that were asked" do
      assert {:error, why} =
               RemotePolicy.among(
                 [host(:"one@127.0.0.1"), host(:"two@127.0.0.1")],
                 "example_scan",
                 :motor_policy
               )

      assert why =~ ~s("example_scan" is offered by no node that hosts plugins)
      assert why =~ ~s("one@127.0.0.1")
      assert why =~ ~s("two@127.0.0.1")
    end

    test "a cluster with no plugin host says so rather than asking nobody" do
      assert {:error, why} = RemotePolicy.among([], "example_scan", :motor_policy)

      assert why =~ "no node in this cluster says it hosts plugins"
    end

    # A plugin says what it needs to answer at all (`MontyPlugin`'s `needs`), and a
    # node can host plugins without having the geometry. Handing the caller a copy
    # on that node is a call that fails inside the plugin, at a step, in a run —
    # where the cluster cannot say why.
    test "a host that cannot serve what the plugin needs is not used", %{provider: provider} do
      MontyPlugin.Registry.offer(
        :motor_policy,
        "example_scan",
        {:ok, needing(provider, [:quiddity])}
      )

      here_without_quiddity = host(node(), ["monty", "plugin"])

      assert {:error, why} =
               RemotePolicy.among([here_without_quiddity], "example_scan", :motor_policy)

      assert why =~ "is offered, but by no node that can serve it"
      assert why =~ "does not offer :quiddity"
    end

    test "a host that offers what the plugin needs is the one used", %{provider: provider} do
      MontyPlugin.Registry.offer(
        :motor_policy,
        "example_scan",
        {:ok, needing(provider, [:quiddity])}
      )

      thin = host(node(), ["monty", "plugin"])
      with_geometry = host(node(), ["monty", "plugin", "quiddity"])

      assert {:ok, %RemotePolicy{pid: ^provider}} =
               RemotePolicy.among([thin, with_geometry], "example_scan", :motor_policy)
    end

    test "a plugin offered but unusable is named, not skipped", %{provider: provider} do
      MontyPlugin.Registry.offer(
        :motor_policy,
        "example_scan",
        {:ok,
         %{name: "example_scan", node: node(), pid: provider, describe: {:error, "no such kind"}}}
      )

      assert_raise ArgumentError, ~r/offered but cannot be used: no such kind/, fn ->
        RemotePolicy.among([here()], "example_scan", :motor_policy)
      end
    end
  end

  defp offering(pid) do
    %{
      node: node(),
      name: "example_scan",
      pid: pid,
      describe: {:ok, %{"name" => "example_scan", "version" => "0.2.0"}}
    }
  end

  # A policy a run holds: resolved to the provider, and the value that provider
  # built for it.
  defp started(provider) do
    %RemotePolicy{
      node: node(),
      name: "example_scan",
      version: "0.1.0",
      pid: provider,
      policy: 0
    }
  end

  defp needing(pid, needs) do
    %{
      node: node(),
      name: "example_scan",
      pid: pid,
      describe: {:ok, %{"name" => "example_scan", "version" => "0.2.0", "needs" => needs}}
    }
  end

  defp here, do: host(node())

  # A host as the poller writes one: the tags it advertises are the question a
  # caller asks before it trusts a plugin to answer.
  defp host(name), do: host(name, ["monty", "plugin"])

  defp host(name, capabilities),
    do: %{node: name, name: to_string(name), capabilities: capabilities}

  defp restore(nil), do: System.delete_env("MONTY_REMOTE_POLICY")
  defp restore(value), do: System.put_env("MONTY_REMOTE_POLICY", value)
end
