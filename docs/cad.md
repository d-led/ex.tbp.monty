# A CAD part in a run

A part can be the world an episode steps: `--world cad`, with `MONTY_CAD_PART`
naming the STEP file. This page says what that is, how to see it, and what is
next.

## What it is

`MontyCad.Scene` (`ex.monty.cad`) is a **scene**, not a world. The port's world
(`Monty.Simulators.Synthetic.Environment`) steps the kinematics, applies the
actions and answers the proprioceptive state; a scene answers only what a sensor
sees. So a part runs through the same world the stand-in sphere does, and only
the picture comes from CAD — one ray-cast pass over the exact B-rep
(`Quiddity.frame/2`) per sensor per step.

Three things this buys, and one it does not:

- **Exactness.** A depth is the point the surface is at, not a renderer's
  approximation of it, and the part's face ids are the recognition's own.
- **Units.** A part is millimetres and the framework is metres; the conversion is
  in the scene and nowhere else, so a policy that moves a centimetre moves a
  centimetre of part.
- **Ground truth.** The scene names the object (`primary_target/1`,
  `semantic_id_to_label/1`), which is what lets a supervised episode score itself
  against a part. The port's world used to answer `nil` unconditionally; it now
  passes a scene's answer through.
- **Not** the experiment. No config was written for a part, so every page says a
  CAD run's numbers are not the experiment's.

## Seeing it

`mix monty.run` needs `MontyCad.Scene` on the node's code path, and the studio
does not depend on `ex_monty_cad` (that package brings quiddity and its Rust
build). A script does it:

```elixir
cad = Path.expand("~/src/ex.monty.cad")

for app <- ["ex_monty_cad", "ex_quiddity"] do
  true = Code.append_path(Path.join([cad, "_build/dev/lib", app, "ebin"]))
end

System.put_env("MONTY_CAD_PART", Path.join(cad, "test/fixtures/golden_simple_through_hole.step"))

Mix.Tasks.Monty.Run.run(["base_10simobj_surf_agent", "--world", "cad", "--episodes", "1", "--steps", "400", "--no-record"])
```

`-pa` does not survive `mix`'s own code-path setup, which is why this is a script
and not a flag. On a node that carries the CAD application the world needs
nothing at all.

Measured on the fixture part: a 64×64 frame costs about 5 ms to cast, and a
400-step surf-agent episode spent 6.7 s in the world and 3.6 s in the model,
issued 3 goals, and concluded nothing — the model it loaded
(`surf_agent_1lm_10similarobj`) was trained on MuJoCo's YCB objects and this is a
bracket it has never seen. That "no conclusion" is the measurement that the next
two steps are for.

## What a scene has to answer

`render/3` takes a pose in metres and answers, for a sensor that looks along its
own −z with depth measured along that axis:

```elixir
%{
  depth: [[float()]],      # metres; 0.0 where the ray met nothing
  rgba: [[[float()]]],     # 0..1 per channel; shading, since a B-rep has no colour
  semantic: [[float()]],   # 1.0 on the part, 0.0 elsewhere
  centre: %{on_object: boolean(), depth: float() | nil, rgba: [float()] | nil}
}
```

Options are the experiment's (`:resolution`, `:zoom`, `:hfov`) and are passed
through by the world. A scene that can also answer `primary_target/1`,
`semantic_id_to_label/1` and `start_pose/2` should: the first two make a
supervised episode possible, and the third is where a sensor starts when the
scene, not a config, knows where the object is.

## What is next, in order

1. **The word `cad` is in every place a run is asked for.** Done:
   `--world cad` (the task), the experiment page's selector, the queued run's
   `Jobs.Run.world_of/1`, the MCP tool and `mix monty.readiness`. The list of
   worlds a node can step is now one answer — `Monty.Studio.Setup.worlds/0`,
   `[:mujoco, :synthetic]` plus `:cad` only when this node carries
   `ex_monty_cad` **and** `MONTY_CAD_PART` names a part — so a page cannot offer
   a world the node would refuse, and a record that names `cad` is asked for
   rather than quietly replaced by the worker's own default.

2. **The feature walk — built and tested, not yet reachable from a run.**
   `MontyCad.Policy.FeatureWalk` (`ade1dd3`, `ex.monty.cad`) walks a part to the
   features its recognition names. Each step it ray-casts from the sensor onto
   the exact surface, corrects the patch's standoff with a `MoveForward`, and
   only then takes one `MoveTangentially` towards the next target — a hole's
   centre, a boss's top; a riser is surface, not a destination. Arrival is the
   ray landing on that feature's own faces, and an empty ray is a through hole's
   aperture rather than a stop. It never reads `observations` or `percept`, which
   is the comparison against a surface policy that has only the patch.

   Held to the part by tests: the fixture is walked to both features, and no
   sideways step is taken from a wrong standoff.

   What is left is the wiring: a CAD host has to register the policy
   (`ex.monty.cad.server`'s `Cluster.register/3`, one provider process, one
   `describe/0`), and a definition has to name it as its `"motor_system"`. The
   studio needs no change for that: `RemotePolicy.among/3` asks every host,
   checks `:quiddity` and `:monty` against the host's carried tags, and refuses
   `:owner_only` on a node that cannot serve it. The control variant — a shell
   around the ported `SurfacePolicyCurvatureInformed`, `:anywhere`,
   `needs: [:monty]` — is still worth having, because it is what the finished
   140-episode run already steered by.

3. **A library the CAD world can be recognised against — the units are done,
   the last mile is not.** `MontyCad.Training` now writes the framework's metres
   and the framework's record shape (`e9bcdca`, `ex.monty.cad`), and a library
   trained from the fixture part loads through `Monty.Studio.Memory.load/3` as a
   `GraphMemory` — checked, not assumed. What is left is _naming_ it: a run picks
   its library from the config's `model_name_or_path`, so recognising against a
   part needs an experiment config of this study's own
   (`priv/monty/libraries/<release>/<name>.jsonl.gz` plus a config naming
   `<name>`) rather than a Monty config borrowed for the occasion.

4. **A part per episode.** A CAD world steps one part; the object-per-episode
   interfaces walk a list. That is where "ten similar parts" becomes an
   experiment rather than a demonstration.
