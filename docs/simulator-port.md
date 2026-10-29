# The simulator port

Monty's world is a Python process (MuJoCo, Habitat, later a camera). It cannot
run in the BEAM, so it sits on the other side of a port, and everything that is
*not* the world — the model, the body, the policies, the learning modules — stays
here.

Elixir side, both written and tested:

| Module | What it is |
| --- | --- |
| `Monty.Simulators.Port.Protocol` | the contract, in both directions |
| `Monty.Simulators.Port.Environment` | the process that owns the port: one request in flight, a timeout that is an error |

Not done: the Python side. `test/support/probe_world.py` speaks the contract but
is a probe, not a world — it answers with what it was sent.

## The world the runtime develops against

Until the peer exists, runs are stepped against
`Monty.Simulators.Synthetic.Environment`, which implements the same idea as a
value (`Monty.Simulators.Environment`): `new/1`, `step/2`, `reset/1`, answering
`{observations, proprioceptive_state, world}`. It moves the agent by the actions
the body chose — `Monty.Simulators.Synthetic.Kinematics` follows MuJoCo's
conventions for the actions it honours — and refuses the ones it does not
instead of silently ignoring them.

It has one object in it: `Monty.Simulators.Synthetic.Scene`, a sphere, so a
sensor reports a depth, an outward normal and two principal curvatures
(`-1/radius`, as Monty's are for a convex surface), and the colour it hit. That
is what a ported surface policy needs to steer by, and it is why
`Monty.Studio.Setup` now builds the **body from the experiment's config**: a
studio run of a surface experiment is `SurfacePolicyCurvatureInformed` choosing
every action, the world moving by them, and the policy seeing the result on the
next step.

The scene renders a **patch**, not a single ray: `Scene.render/3` answers depth,
colour and semantic images from a pinhole camera, described the way Monty's own
experiments describe theirs — a resolution in pixels, a zoom, and Habitat's
90-degree field of view. The studio reads those numbers out of the experiment's
agent, so `base_10simobj_surf_agent` renders its patch 64 pixels across at ten
times zoom, which is `fx = tan(hfov / 2) / zoom = 0.1` on the image plane.

That is not decoration. `DepthTo3DLocations` unprojects a depth image with
exactly those numbers, so a world rendering a different camera would make the
transform disagree with it about which ray a pixel came from. Depth is measured
along the sensor's axis rather than along the ray, as a depth camera measures
it, for the same reason: unprojecting a ray distance as an axis depth puts the
point somewhere the surface is not.

One pixel is the default, and it is a ray.

Where the episode **starts** comes from the experiment too. `base_10simobj_surf_agent`
puts the agent 0.2 m from the object's centre with its patch camera on the agent
and its view finder 3 cm behind it, and the sphere goes where the config puts the
object. That is what makes the body behave like Monty's: from there the surface
policy's own `_move_to_visible_object` steps forward until the view finder is at
`desired_object_distance`, which brings the patch within a finger's 5 cm reach,
and only then does it start sampling movements along the surface. A world that
started with its cameras already touching the object would never show that.

The stand-in's own placement — a decimetre back, a centimetre apart — is only
what a world with no scene description falls back to.

The sensor makes of that what Monty's `CameraSM` makes of a depth image: a signed
logarithm of the curvatures (`principal_curvatures_log`) and the centre pixel as
hue, saturation and value (`hsv`, by the conversion `skimage` supplies and
`Monty.Frameworks.Utils.SensorProcessing.rgb2hsv/1` reproduces). The names are
the ones `feature_weights` in Monty's configs use, so a learning module built
from a config finds every feature it was told to weight.

What it is not: Monty's world. A sphere's numbers are not MuJoCo's, so a run
against it says whether the parts agree with each other — not whether they agree
with Monty. Only the peer below can answer the second question.

## The contract

Framing is a four-byte big-endian length then UTF-8 JSON, which is Erlang's
`{:packet, 4}`; the peer writes the same four bytes itself. One request, one
reply, both carrying an `id`, so a late reply to a request that already timed out
is recognisable instead of being read as this one.

```json
→ {"id": 1, "command": "reset", "sensor_ids": ["patch"]}
← {"id": 1, "ok": true}

→ {"id": 2, "command": "step",
   "actions": [{"action": "move_forward", "agent_id": "agent_id_0", "distance": 0.004}]}
← {"id": 2,
   "observations": {"agent_id_0": {"patch": {"location": [0, 0, 0.2], "...": "..."}}},
   "proprioceptive_state": {"agent_id_0": {"position": [0, 0, 0],
                                           "rotation": [1, 0, 0, 0],
                                           "sensors": {"patch": {"position": [0, 0, 0.1],
                                                                 "rotation": [1, 0, 0, 0]}}}}}

← {"id": 2, "error": "the sensor id is not known"}
```

The action maps are Monty's own `dict(action)` — `ActionJSONEncoder` on this side,
so the peer parses what Monty's simulator already parses. Units are Monty's:
metres, degrees, quaternions `wxyz`, poses relative to the agent.

## What the peer must do

1. Read a length, then that many bytes; answer with a length, then JSON.
2. Answer `reset` by putting the world into its first-step state, and `step` by
   advancing the world by the actions it was given, then reporting every sensor
   named at `reset`.
3. Keep stdout for JSON only. Log to stderr — stdout is the channel.
4. Never send a reply for a request it did not receive in full; a partially read
   frame would desynchronise the stream for ever.

## Why a port and not a NIF

A NIF blocks a scheduler for as long as the simulator runs, cannot be
interrupted, and takes the VM down when it segfaults. MuJoCo does all three. The
port costs one copy per step and buys isolation, a timeout that works, and the
ability to run the simulator on another machine later.

## The next step

Whoever installs MuJoCo or Habitat writes the peer against the contract above and
points `Monty.Simulators.Port.Environment` at it — as a function for
`Monty.Runtime.Episode`, or behind the same value-shaped interface the stand-in
world implements. Its `proprioceptive_state` is parsed into
`AgentState`/`SensorState` there, because that is the shape the body reads.

Then the sphere goes away, and `base_10simobj_surf_agent` becomes comparable with
Monty's own numbers.
