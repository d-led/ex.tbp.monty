defmodule FlyversePlugin.OfferTest do
  @moduledoc """
  The wire, not the modules: a caller reaches a plugin by its registered process
  and asks the four things `MontyPlugin` says a provider answers.

  This is the shape `Monty.Studio.RemotePolicy` sends — `{:new, options}`,
  `{:call, policy, ctx, observations, state, percept, goals}`, `{:reset, policy}`,
  `{:state_dict, policy}` — so a test here is the closest thing to the studio's
  call that fits in one node.

  Not async: which pack this node steps is application configuration.
  """

  use ExUnit.Case, async: false

  alias FlyversePlugin.{Demonstrator, Pack, Policy}
  alias Monty.Frameworks.Models.MotorPolicies.MotorPolicyResult

  setup do
    directory =
      Path.join(System.tmp_dir!(), "flyverse_offer_#{System.unique_integer([:positive])}")

    {:ok, _written} = Pack.write(directory, Demonstrator.spec())

    Application.put_env(:flyverse_plugin, :pack, directory)

    on_exit(fn ->
      Application.delete_env(:flyverse_plugin, :pack)
      File.rm_rf!(directory)
    end)

    {:ok, provider} = MontyPlugin.Registry.lookup(:motor_policy, Policy.name())

    {:ok, pid: provider.pid}
  end

  test "the experiment answers its definition, and nothing it does not decide", %{pid: _pid} do
    {:ok, provider} = MontyPlugin.Registry.lookup(:experiment, FlyversePlugin.Experiment.name())

    assert {:ok, %{"base" => "base_10simobj_surf_agent"}} = GenServer.call(provider.pid, :run)

    assert {:error, sentence} = GenServer.call(provider.pid, {:new, []})
    assert sentence =~ "is not a motor policy"
  end

  test "a policy is started, stepped, recorded and reset over the process", %{pid: pid} do
    assert {:ok, policy} = GenServer.call(pid, {:new, []})

    assert {:ok, %MotorPolicyResult{} = result, policy} =
             GenServer.call(pid, {:call, policy, nil, near_left(), nil, nil, [nil]})

    assert [%Monty.Frameworks.Actions.OrientHorizontal{}] = result.actions
    assert result.telemetry.left_spikes > 0

    assert {:ok, recorded} = GenServer.call(pid, {:state_dict, policy})
    assert recorded.wish > 0.0

    assert {:ok, policy} = GenServer.call(pid, {:reset, policy})

    assert {:ok, again, _policy} =
             GenServer.call(pid, {:call, policy, nil, near_left(), nil, nil, [nil]})

    assert again.actions == result.actions
  end

  test "a node with no pack refuses a policy with a sentence, not a crash" do
    Application.delete_env(:flyverse_plugin, :pack)
    System.delete_env("FLYVERSE_PACK")

    {:ok, provider} = MontyPlugin.Registry.lookup(:motor_policy, Policy.name())

    assert {:error, sentence} = GenServer.call(provider.pid, {:new, []})
    assert sentence =~ "FLYVERSE_PACK"
  end

  defp near_left do
    %{
      "agent_id_0" => %{
        "view_finder" => %{"depth" => [[0.02, 0.02, 100.0, 100.0]]},
        "patch" => %{"depth" => [[0.02, 0.02, 100.0, 100.0]]}
      }
    }
  end
end
