defmodule Monty.Simulators.Habitat.Environment.HabitatEnvironmentTest do
  @moduledoc """
  Monty's world, against a peer that is not Habitat.

  `test/support/probe_world.py` stands in for `scripts/monty_simulator_peer.py`.
  What is under test is the lifecycle — nothing starts until a step needs it, one
  process serves the episode, a reset is a new episode in that process, and
  stopping closes it — because the scene itself is Monty's and runs in Monty's
  own Python environment, which a test here cannot rely on being installed.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Actions.MoveForward
  alias Monty.Frameworks.Models.MotorSystemState.AgentState
  alias Monty.Simulators.Habitat.Environment.HabitatEnvironment

  @peer Path.expand("../../../../support/probe_world.py", __DIR__)

  defp world(options \\ []) do
    HabitatEnvironment.new(
      Keyword.merge(
        [
          experiment: "base_config_10distinctobj_dist_agent",
          sensors: ["patch"],
          python: System.find_executable("python3"),
          peer: @peer
        ],
        options
      )
    )
  end

  test "a step is what the sensors see and where the agent is" do
    {observations, proprioceptive_state, world} =
      HabitatEnvironment.step(world(), [
        %MoveForward{agent_id: "agent_id_0", distance: 0.004}
      ])

    assert get_in(observations, ["agent_id_0", "patch", "location"]) |> Enum.at(2) == 0.1
    assert %{"agent_id_0" => %AgentState{} = agent} = proprioceptive_state
    assert agent.position == [0.0, 0.0, 0.0]

    # The world a step leaves behind is the same world, now serving.
    assert %HabitatEnvironment{server: server} = world
    assert is_pid(server)

    HabitatEnvironment.stop(world)
  end

  test "nothing starts until a step asks the world for something" do
    assert %HabitatEnvironment{server: nil} = world()
  end

  test "one process serves the whole episode" do
    {_observations, _state, world} = HabitatEnvironment.step(world(), [])
    {_observations, _state, world} = HabitatEnvironment.step(world, [])
    {_observations, _state, again} = HabitatEnvironment.step(world, [])

    assert again.server == world.server

    HabitatEnvironment.stop(again)
  end

  test "a reset is the next episode, in the world that is already running" do
    {_observations, _state, world} = HabitatEnvironment.step(world(), [])

    reset = HabitatEnvironment.reset(world)

    assert reset.server == world.server

    # Monty's `Interface` takes the no-action step that follows a reset, and
    # that is what shows the new episode's first view.
    {observations, %{"agent_id_0" => %AgentState{}}, _world} =
      HabitatEnvironment.step(reset, [])

    assert get_in(observations, ["agent_id_0", "patch", "location"]) != nil

    HabitatEnvironment.stop(reset)
  end

  test "a world that never stepped has nothing to close" do
    assert :ok = HabitatEnvironment.stop(world())
  end

  test "a run closes the peer it stepped" do
    {_observations, _state, world} = HabitatEnvironment.step(world(), [])
    %HabitatEnvironment{server: server} = world

    ref = Process.monitor(server)
    assert :ok = Monty.Simulators.Environment.stop(world)
    assert_receive {:DOWN, ^ref, :process, ^server, _reason}
  end

  test "the peer is told where Monty's source is, and the scene by name" do
    world = world()

    assert world.command |> Enum.take(2) |> List.last() == @peer
    assert "--experiment" in world.command
    assert world.experiment in world.command

    assert match?([{"PYTHONPATH", _path}], world.env)
  end
end
