# The studio asks a peer for a policy by name — `MontyPlugin.Registry.lookup/2`
# over `:rpc` — and does not depend on the package that answers, so the module
# that name resolves to can be this one. Nothing else in this tree defines it; it
# exists so a case can be the node on the far side of the call.
defmodule MontyPlugin.Registry do
  @moduledoc false

  @offers {__MODULE__, :offers}

  def offer(kind, name, answer),
    do: :persistent_term.put(@offers, Map.put(offers(), {kind, name}, answer))

  def clear, do: :persistent_term.put(@offers, %{})

  def lookup(kind, name), do: Map.get(offers(), {kind, name}, {:error, :not_offered})

  defp offers, do: :persistent_term.get(@offers, %{})
end

defmodule Monty.Studio.RemotePolicyTest do
  @moduledoc """
  What a policy on another node owes a step, and what the studio owes it back.

  The policy struct never crosses — the process on the plugin's node *is* the
  state — so the cases here are about that seam: a step is answered by the
  process, remembered by the process, and a policy that has gone away says so
  rather than producing a step nobody decided. Which node offers it is the other
  half, and that half is a question (`among/3`), not a run.

  Not async: a node's environment and the stand-in's table are the node's, and
  one case here sets what the node was told to run.
  """

  use ExUnit.Case, async: false

  alias Monty.Frameworks.Models.MotorPolicies.MotorPolicyResult
  alias Monty.Studio.RemotePolicy

  defmodule Provider do
    @moduledoc false
    use GenServer

    def start_link(calls), do: GenServer.start_link(__MODULE__, calls)

    @impl true
    def init(calls), do: {:ok, calls}

    @impl true
    def handle_call({:call, _ctx, _observations, _state, _percept, goals}, _from, calls) do
      {:reply, {:ok, %MotorPolicyResult{actions: [{:step, calls, length(goals)}]}}, calls + 1}
    end

    def handle_call(:reset, _from, _calls), do: {:reply, :ok, 0}
    def handle_call(:state_dict, _from, calls), do: {:reply, %{steps: calls}, calls}
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
      policy: %RemotePolicy{node: node(), name: "example_scan", version: "0.1.0", pid: provider},
      provider: provider
    }
  end

  test "a step is decided by the process that offers the policy", %{policy: policy} do
    assert {%MotorPolicyResult{actions: [{:step, 0, 1}]}, ^policy} =
             RemotePolicy.call(policy, %{}, nil, %{}, nil, [%{}])
  end

  test "the policy remembers on its own node, not in what the studio holds", %{policy: policy} do
    {_first, policy} = RemotePolicy.call(policy, %{}, nil, %{}, nil, [])
    {_second, policy} = RemotePolicy.call(policy, %{}, nil, %{}, nil, [])

    assert RemotePolicy.state_dict(policy) == %{
             steps: 2,
             policy: "example_scan",
             version: "0.1.0",
             node: node()
           }
  end

  test "starting an episode reaches the node that owns the state", %{policy: policy} do
    {_first, policy} = RemotePolicy.call(policy, %{}, nil, %{}, nil, [])

    assert RemotePolicy.reset(policy) == policy
    assert RemotePolicy.state_dict(policy).steps == 0
  end

  test "a policy whose node has gone says which policy stopped answering", %{policy: policy} do
    stop_supervised!(Provider)

    assert_raise ArgumentError,
                 ~r/example_scan on #{Regex.escape(to_string(node()))} stopped answering/,
                 fn ->
                   RemotePolicy.call(policy, %{}, nil, %{}, nil, [])
                 end
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
                %RemotePolicy{node: node(), name: "example_scan", version: "0.2.0", pid: provider}}
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
