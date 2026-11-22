# What the world's answer costs between the render and the model.
#
#   MIX_ENV=test mix run scripts/probe_world_crossing.exs [experiment] [world]
#
# A step's world phase is three things: MuJoCo drawing (`ex_mujoco`'s Rust),
# the render's bytes turning into the nested lists a model reads
# (`Simulator.decode/4`), and the transform chain walking those lists
# (`MissingToMaxDepth` then `DepthTo3DLocations`). Only the first is someone
# else's, so this prices the other two on one real observation: the same shapes,
# the same values, measured in place rather than inferred from a profile's
# shares. It also prices what a sensor does with one observation, because that
# is the other half of the crossing.
#
# Measured 2026-11-22, `base_config_10distinctobj_dist_agent`, `ex_mujoco`, this
# Mac: transforms 1 137 µs a step for both sensors, `rows(depth)` 101 µs and
# `rows(rgba)` 74 µs a sensor, the patch sensor's own step 1 376 µs. Against a
# step of about 25 ms those are single-figure percentages, which is why the
# pictures stay lists: turning them into bytes and decoding them per reader
# measured **+20 %** reductions (`docs/speed.md`, "Tried and rejected").
#
# `reruns` repeats each measurement and reports the fastest, because the first
# call in a fresh process pays for code loading.

alias Monty.Experiment.Environment.Interface
alias Monty.Simulators.ExMujoco.Simulator
alias Monty.Studio

Code.require_file("probe_support.exs", __DIR__)

experiment = System.argv() |> Enum.at(0, "base_config_10distinctobj_dist_agent")
world = System.argv() |> Enum.at(1, "ex_mujoco") |> String.to_existing_atom()

reruns = 20

fastest = fn fun ->
  1..reruns
  |> Enum.map(fn _ -> {micros, _} = :timer.tc(fun); micros end)
  |> Enum.min()
end

opened = ProbeSupport.setup(experiment, world_simulator: world)
{:ok, run} = Studio.Run.start(opened.setup, steps: 4)
:ok = Studio.Run.set_ground_truth(run)
{:ok, _info, observations, run} = Studio.Run.step(run)

interface = run.interface
proprioceptive = %{}

IO.puts("#{experiment}, world #{world}")
IO.puts("the transform chain: #{inspect(Enum.map(interface.transforms, & &1.__struct__))}")

IO.puts(
  "transforms, one step of both sensors: #{fastest.(fn ->
    Interface.apply_transforms(interface, observations, proprioceptive)
  end)} us"
)

# The other half: what the render's bytes cost to become nested lists, measured
# on the same images turned back into the bytes a renderer answers with.
for {sensor_id, sensor} <- observations["agent_id_0"], is_list(sensor["depth"]) do
  width = length(hd(sensor["depth"]))
  depth_bytes = for row <- sensor["depth"], value <- row, into: <<>>, do: <<value::float-32-little>>
  rgba_bytes =
    for row <- sensor["rgba"], pixel <- row, into: <<>>, do: <<Enum.at(pixel, 0)::8, Enum.at(pixel, 1)::8, Enum.at(pixel, 2)::8>>

  IO.puts(
    "#{sensor_id}: #{length(sensor["depth"])}x#{width} — rows(depth) " <>
      "#{fastest.(fn -> Simulator.rows(depth_bytes, width, :depth) end)} us, " <>
      "rows(rgba) #{fastest.(fn -> Simulator.rows(rgba_bytes, width, :rgba) end)} us"
  )
end

# And what the sensor does with it: `ObservationProcessor.process/2` is the whole
# of a CameraSM's step, and its share is what a patch kernel would replace.
alias Monty.Frameworks.Models.SensorModules.ObservationProcessor

processor =
  ObservationProcessor.new(
    features: [
      "pose_vectors",
      "pose_fully_defined",
      "on_object",
      "object_coverage",
      "hsv",
      "principal_curvatures_log"
    ],
    sensor_module_id: "patch"
  )

patch = observations["agent_id_0"]["patch"]

IO.puts(
  "the sensor's step, one observation: #{fastest.(fn ->
    ObservationProcessor.process(processor, patch)
  end)} us"
)
