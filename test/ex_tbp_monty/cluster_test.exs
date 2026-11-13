defmodule ExTbpMonty.ClusterTest do
  @moduledoc """
  What a node starts when it was asked to cluster, and what it starts when it was
  not.

  The switch is application configuration, so these cases cannot run beside a case
  that expects the other answer: `async: false`, and each one puts the setting
  back where it found it.
  """

  use ExUnit.Case, async: false

  alias ExTbpMonty.Cluster

  setup do
    previous = Application.get_env(:ex_tbp_monty, :cluster)

    on_exit(fn -> Application.put_env(:ex_tbp_monty, :cluster, previous) end)

    :ok
  end

  describe "a node that was not asked to cluster" do
    test "starts nothing at all" do
      configure(enabled: false, seeds: [])

      refute Cluster.enabled?()
      assert Cluster.children() == []
    end

    test "has no registry and no supervisor running" do
      # The application this suite runs in was started with the default, so this
      # is the tree everybody else's tests see too.
      configure(enabled: false, seeds: [])

      refute Process.whereis(Cluster.registry())
      refute Process.whereis(Cluster.supervisor())
    end
  end

  describe "a node that was asked" do
    test "starts a topology, a registry and a supervisor, in that order" do
      # The topology first: Horde's `members: :auto` reads `Node.list/0`, so
      # whatever fills it in has to be there before the CRDT is told about it.
      # The child's *id* is the module Horde is started from — the name it is
      # called in this application is an option, and asserted below.
      configure(enabled: true, seeds: [])

      assert [
               {Elixir.Cluster.Supervisor, [_topologies]},
               {Horde.Registry, registry},
               {Horde.DynamicSupervisor, supervisor}
             ] = Cluster.children()

      assert registry[:name] == Cluster.registry()
      assert registry[:keys] == :unique
      assert supervisor[:name] == Cluster.supervisor()
      assert supervisor[:distribution_strategy] == Horde.UniformDistribution
    end

    test "joins the seeds it was given" do
      hosts = [:"monty@127.0.0.1", :"monty2@127.0.0.1"]

      configure(enabled: true, seeds: hosts)

      assert Cluster.seeds() == hosts

      assert [default: [strategy: Elixir.Cluster.Strategy.Epmd, config: [hosts: ^hosts]]] =
               Cluster.topologies()
    end

    test "looks for its neighbours when nobody named them" do
      # Three `mix phx.server` processes on one machine know no names to dial, so
      # gossip is how they find each other: it is a real strategy, not a fallback.
      configure(enabled: true, seeds: [])

      assert [default: [strategy: Elixir.Cluster.Strategy.Gossip]] = Cluster.topologies()
    end

    test "is still a cluster of one until a peer connects" do
      configure(enabled: true, seeds: [])

      assert Cluster.nodes() == [node()]
    end
  end

  # The child's own id: a `{module, argument}` spec is keyed by its module, and
  # `Supervisor.child_spec/2` would say the same thing in more words.
  defp configure(settings), do: Application.put_env(:ex_tbp_monty, :cluster, settings)
end
