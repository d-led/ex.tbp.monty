# Stage 3: the memory a CAD run wrote, read by a run whose world is a mesh.
#
#   mix run scripts/cad_mesh_eval.exs
#
# The part is written as an object set the MuJoCo world steps — `textured.obj`,
# `texture_map.png`, `metadata.json`, in metres, at its own scale — under the name
# the memory carries. The world is then MuJoCo and nothing on the run's path asks
# quiddity anything: if a recognition happens here, it is Monty's.
#
# The memory is the one `scripts/cad_experiment.exs` wrote for `plate`; run that
# first, or point `libraries` below at wherever a memory of the part lives.

part = Path.expand("../priv/cad_experiments/parts/plate.step", __DIR__)
libraries = "/tmp/cad-experiment/plate"
name = "plate"

objects = Path.join(Monty.Paths.data(), "cad_objects")

# The config names its objects under `$MONTY_DATA` and this writes them under the
# data root — so the root is stated rather than assumed, and the two agree by
# construction instead of by a default that happens to match.
System.put_env("MONTY_DATA", Monty.Paths.data())

{:ok, mesh} = MontyCad.Export.part_mesh(part, name: name)
row = ExTbpMonty.Cad.Objects.write_mesh(mesh, objects)

IO.puts("object: #{row.object} — #{row.faces} faces, #{row.vertices} vertices, in #{objects}")
IO.puts("memory: #{libraries} — reading #{name}\n")

Application.put_env(:ex_tbp_monty, :monty_libraries_dir, libraries)

Mix.Tasks.Monty.Run.run([
  "cad_mesh_eval",
  "--world",
  "mujoco",
  "--overlay",
  "priv/cad_experiments/conf",
  "--episodes",
  "1",
  "--steps",
  "500",
  "--record"
])
