# The CAD experiment: build a memory from CAD parts, then recognise one of them
# in the CAD world. This is `docs/cad.md` item 3, runnable.
#
#   mix run scripts/cad_experiment.exs                      # the plate, alone
#   mix run scripts/cad_experiment.exs plate blend          # two parts, sense the blend
#   mix run scripts/cad_experiment.exs plate blend blend-big # three
#
# A name is matched to a STEP file this checkout has: `plate` is the CAD
# package's fixture (a boss and a through hole), `blend` and `blend-big` are
# quiddity's two sizes of one fillet. The last name given is the part the world
# steps; every name before it is a memory the run may choose between.
#
# Why the sibling builds are on the code path: this application carries the
# framework, not the geometry. `Monty.Studio.Setup` opens a part through
# `MontyCad.Scene` when one is loaded, and `MontyCad.Training` writes the memory
# a run reads — both live in `ex_monty_cad`, which the studio deliberately does
# not depend on (`docs/cad.md`, first section). A node that carries that package
# needs none of this.
#
# The memory is written to a directory of its own and pointed at with
# `:monty_libraries_dir`, at the address the config's `model_name_or_path`
# already names (`<release>/surf_agent_1lm_10distinctobj.jsonl.gz`), so no
# config is edited to try it.

parts = %{
  "plate" => Path.expand("~/src/ex.monty.cad/test/fixtures/golden_simple_through_hole.step"),
  "blend" => Path.expand("~/src/ex.quiddity/test/fixtures/blend_r5.step"),
  "blend-big" => Path.expand("~/src/ex.quiddity/test/fixtures/blend_r5_enlarged.step"),
  "plate-big" => Path.expand("/tmp/cad-experiment/parts/plate_big.step"),
  "plate-huge" => Path.expand("/tmp/cad-experiment/parts/plate_huge.step")
}

# Two parts that differ in one thing only — size — while both have a pose the
# sensor can name (a rounded block's cannot, `docs/cad.md`). They are derived
# rather than checked in: the same nine faces and eighteen edges, and every
# point *and* every radius scaled, because a file with scaled points and
# unscaled radii is a different, broken part and the numbers are the only place
# the geometry lives.
#
# Two scales, because the question they ask is where the feature tolerances
# stop telling sizes apart: `principal_curvatures_log` is compared with a
# tolerance of 1.0, and a scale `s` moves a curvature by `log s` — 0.4 at 1.5×,
# 1.6 at 5×. A pair the sensor cannot separate by feature is not a test of
# matching, it is a test of which graph wins a tie.
derived = %{
  "plate-big" => {"plate", 1.5},
  "plate-huge" => {"plate", 5.0}
}

# Sampling is relative to the part, unless `CAD_ABSOLUTE_SPACING=1` asks for the
# absolute dial. A fixed spacing gives a 5× part the same number of nodes over
# twenty-five times the area, so a library of two sizes is also a library of two
# node densities — and the denser graph wins: sensing the 5× part against a
# library of both concluded the *small* one at evidence 15.5, and at 1.5× it did
# the same at 12.0. Sample each part at its own scale's spacing and the two
# memories hold about as many nodes (1557 against 1581 at 1.5×, 1557 against
# 1602 at 5×), and both questions come out right: the sensed part is the one on
# top in every seed, at higher evidence than either wrong answer had.
#
# The rule is one sentence rather than a table of scales: never finer than two
# millimetres, never coarser than the part's largest extent over thirty. The
# floor is what a single part has always been written with — a 60 mm plate is
# 2.0 both ways — so the single-part rates above are untouched, while a part
# five times the size is sampled at 10 mm and gets a memory of the same size.
#
# The absolute dial is kept because it is what every measurement before this was
# made with, and a rate over seeds that changed two things would say nothing.
base_spacing = 2.0
absolute? = System.get_env("CAD_ABSOLUTE_SPACING") in ["1", "true"]

spacing = fn part, absolute? ->
  if absolute? do
    base_spacing
  else
    extent = part.summary["extent"] |> Enum.max()
    max(base_spacing, extent / 30)
  end
end

scaled = fn source, target, scale ->
  # `Float.parse/1` leaves the rest of the number behind: a STEP real may be
  # written `4.`, which it reads as `4.0` and a stray `.` it does not consume.
  real = fn value ->
    {number, _rest} = Float.parse(value)
    Float.to_string(number * scale)
  end

  text =
    Regex.replace(
      ~r/(CIRCLE|CYLINDRICAL_SURFACE|SPHERICAL_SURFACE|TOROIDAL_SURFACE)\('',(\s*#\d+)\s*,\s*([-0-9.eE+]+)\)/,
      File.read!(source),
      fn _, kind, axis, radius -> "#{kind}('',#{axis},#{real.(radius)})" end
    )

  text =
    Regex.replace(~r/CARTESIAN_POINT\('',\(([^)]*)\)\);/, text, fn _, coords ->
      numbers = coords |> String.split(",") |> Enum.map_join(",", real)
      "CARTESIAN_POINT('',(#{numbers}));"
    end)

  File.write!(target, text)
end

for ebin <- [
      Path.expand("~/src/ex.monty.cad/_build/dev/lib/ex_monty_cad/ebin"),
      Path.expand("~/src/ex.monty.cad/_build/dev/lib/ex_quiddity/ebin"),
      Path.expand("~/src/ex.cadmpeg/_build/dev/lib/ex_cadmpeg/ebin")
    ] do
  Code.append_path(ebin) || :already_on_the_path
end

names = System.argv()

# The remembered parts, and the one the world steps. The last name is remembered
# too unless `CAD_SENSE_ONLY` asks otherwise: sensing a part the memory does not
# hold is the control that says whether the run's answer means anything — a run
# that names the part it was told about has measured its own memory, and a run
# that names something else has not recognised at all.
{sensed, remembered} =
  case names do
    [] -> {"plate", []}
    given -> {List.last(given), Enum.drop(given, -1)}
  end

sense_only? = System.get_env("CAD_SENSE_ONLY") in ["1", "true"]
memory = Enum.uniq(remembered ++ if(sense_only?, do: [], else: [sensed]))

# A derived part is written when a run names it, so a run that does not is not
# made to depend on a writable `/tmp`.
for name <- Enum.uniq(memory ++ [sensed]), Map.has_key?(derived, name) do
  {from, scale} = Map.fetch!(derived, name)
  File.mkdir_p!(Path.dirname(parts[name]))
  scaled.(parts[from], parts[name], scale)
end

if memory == [] do
  Mix.raise(
    "CAD_SENSE_ONLY needs a part to remember: mix run scripts/cad_experiment.exs <remembered> <sensed>"
  )
end

unknown = Enum.reject(memory ++ [sensed], &Map.has_key?(parts, &1))

if unknown != [] do
  Mix.raise("unknown part(s) #{inspect(unknown)}; this script knows #{inspect(Map.keys(parts))}")
end

folder = Enum.join(memory, "+") <> if(sense_only?, do: "+control", else: "")
libraries = Path.expand("/tmp/cad-experiment/#{folder}")
release = "pretrained_ycb_v14"
name = "surf_agent_1lm_10distinctobj"
path = Path.join([libraries, release, name <> ".jsonl.gz"])
File.mkdir_p!(Path.dirname(path))

# One JSON line per object, which is what Monty's own libraries hold (checked
# against `pretrained_ycb_v14/surf_agent_1lm_10distinctobj`: ten objects, ten
# lines) and what `Monty.Studio.Memory.load/3` reads back.
records =
  for object_id <- Enum.uniq(memory) do
    {:ok, part} = Quiddity.open(parts[object_id])
    {:ok, recognition} = Quiddity.features(part)

    each = Path.join([libraries, "each", object_id <> ".jsonl.gz"])

    {:ok, written} =
      MontyCad.Training.write(part, object_id, each,
        recognition: recognition,
        spacing: spacing.(part, absolute?)
      )

    IO.puts(
      "#{object_id}: #{written.nodes} nodes, #{written.skipped} skipped, " <>
        "families #{inspect(written.families)}"
    )

    each |> File.read!() |> :zlib.gunzip() |> String.split("\n", trim: true)
  end

path |> then(&File.write!(&1, :zlib.gzip(Enum.join(records, "\n"))))

control = if(sense_only?, do: " (control: the sensed part is not remembered)", else: "")

IO.puts("memory: #{path} — #{length(records)} object(s), sensing #{sensed}#{control}\n")

Application.put_env(:ex_tbp_monty, :monty_libraries_dir, libraries)
System.put_env("MONTY_CAD_PART", parts[sensed])

# The seed is the input a rate over seeds varies: one episode recognising a part
# says it can happen, ten say how often.
seed = System.get_env("CAD_SEED")

Mix.Tasks.Monty.Run.run(
  [
    "base_config_10distinctobj_surf_agent",
    "--world",
    "cad",
    "--episodes",
    "1",
    "--steps",
    "500",
    "--no-record"
  ] ++ if(seed in [nil, ""], do: [], else: ["--seed", seed])
)
