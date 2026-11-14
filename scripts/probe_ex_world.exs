# Does the ex_mujoco world build the experiment's scene, and look at it?
#
#   MIX_ENV=test mix run --no-start scripts/probe_ex_world.exs [experiment]
#
# One episode's world, reset, then a few steps: the shapes a sensor module will be
# handed, the spread of the depth image, and the ids it reads. What it has to
# answer is whether the object is in front of the patch — a patch reading one flat
# plane is the table, and a run of those is the failure this world would have if
# its scene were built wrong. The scene it would compile is written to
# /tmp/ex_scene.xml first, because MuJoCo's own answer to a model it will not
# compile says more than the NIF's buffer does.

alias Monty.Frameworks.Actions.MoveForward
alias Monty.Simulators.ExMujoco.{Scene, World}
alias Monty.Studio
alias Monty.Studio.Setup

experiment = System.argv() |> List.first() || "base_10simobj_surf_agent"

IO.puts("renderer: #{inspect(ExMujoco.Renderer.available?())}")
IO.puts("reason: #{inspect(ExMujoco.Renderer.unavailable_reason())}")

{:ok, opened} = Studio.open(experiment, world_simulator: :ex_mujoco)
setup = opened.setup
IO.puts("world: #{Setup.world_name(setup, :ex_mujoco)}")
IO.puts("data path: #{inspect(setup.environment && setup.environment.data_path)}")
IO.puts("agent: #{inspect(setup.agent_class)} at #{inspect(setup.scene.agent.position)}")

world = Setup.world(setup, :ex_mujoco, 0)

%{xml: xml} = Scene.build(world.spec)
File.write!("/tmp/ex_scene.xml", xml)
IO.puts("scene: #{byte_size(xml)} bytes at /tmp/ex_scene.xml")

world = World.reset(world)
IO.puts("primary target: #{inspect(world.primary_target)}")
IO.puts("labels: #{inspect(world.semantic_id_to_label)}")

agent_id = Monty.Simulators.Synthetic.Environment.agent_id()

step = fn index, world ->
  started = System.monotonic_time(:microsecond)

  {observations, state, world} =
    World.step(world, [%MoveForward{agent_id: agent_id, distance: 0.004}])

  took = System.monotonic_time(:microsecond) - started

  sensors =
    Enum.map_join(observations[agent_id], ", ", fn {sensor_id, seen} ->
      depth = seen["depth"] |> List.flatten()

      "#{sensor_id}: depth #{Float.round(Enum.min(depth), 4)}..#{Float.round(Enum.max(depth), 4)} " <>
        "rgba #{inspect(seen["rgba"] |> List.flatten() |> Enum.take(6))} " <>
        "ids #{inspect(seen["semantic"] |> List.flatten() |> Enum.frequencies())}"
    end)

  IO.puts("step #{index} (#{div(took, 1000)} ms): #{sensors}")
  IO.puts("   agent at #{inspect(state[agent_id].position)}")

  world
end

Enum.reduce(1..4, world, step)
