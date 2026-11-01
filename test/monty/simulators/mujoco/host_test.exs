defmodule Monty.Simulators.Mujoco.HostTest do
  @moduledoc """
  The world host, stepped for real: `priv/monty_py/world.py` in this
  application's own interpreter.

  An empty scene — no agents, no objects — is enough to hold the seam: what is
  being checked here is that a world opens, resets, steps and closes through one
  process, and that a world that is not open or cannot be built is answered with
  words rather than a crash. Objects in a scene need mesh data, which is a
  prerequisite and not something this suite carries.
  """

  use ExUnit.Case, async: false

  alias Monty.Simulators.Mujoco.Host

  @empty_scene %{}

  defp open(tag) do
    id = "host-test-#{tag}-#{System.unique_integer([:positive])}"
    :ok = Host.start_world(id, @empty_scene)
    on_exit(fn -> Host.stop_world(id) end)
    id
  end

  describe "a world that is open" do
    test "resets with the episode's first observations" do
      world = open("reset")

      assert {:ok, answer} = Host.reset(world)

      assert answer["observations"] == %{}
      assert answer["proprioceptive_state"] == %{}
      assert answer["semantic_id_to_label"] == %{}
      assert answer["primary_target"] == nil
    end

    test "steps with the actions the model chose, and answers what came back" do
      world = open("step")

      assert {:ok, %{"observations" => _, "proprioceptive_state" => _}} = Host.step(world, [])
    end

    test "can be stepped after a reset, in the same world" do
      world = open("episode")

      assert {:ok, _} = Host.reset(world)
      assert {:ok, _} = Host.step(world, [])
    end

    test "closes, and closing it again is not an error" do
      world = open("close")

      assert :ok = Host.stop_world(world)
      assert :ok = Host.stop_world(world)
    end
  end

  describe "a world that is not open" do
    # A run that outlives its simulator asks anyway: the answer is the reason,
    # not a crash that takes the host and every other run's world with it.
    test "cannot be reset, and is told why" do
      assert {:error, reason} = Host.reset("no-such-world")

      assert reason =~ "the simulator was closed with it"
    end

    test "cannot be stepped, and is told why" do
      assert {:error, reason} = Host.step("no-such-world", [])

      assert reason =~ "the simulator was closed with it"
    end
  end

  describe "a world that cannot be built" do
    test "answers with the reason, and the host serves the next world" do
      # An object with no mesh data: the scene is refused where it is built.
      assert {:error, reason} =
               Host.start_world("cannot-build", %{"objects" => [%{"name" => "mug"}]})

      assert reason =~ "Monty's MuJoCo simulator failed"
      assert reason =~ "data_path"

      world = open("after-a-failure")
      assert {:ok, _} = Host.reset(world)
    end
  end
end
