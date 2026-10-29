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
conventions for the six actions it honours — and refuses the ones that need a
surface instead of silently ignoring them.

What it is not: geometry. Nothing is out there, so its observations are its own
poses, and a run against it says nothing about a learned object. It exists to
keep the runtime honest — the model's actions change what the model sees next —
not to produce numbers comparable with Monty's.

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
`Monty.Runtime.Episode`, or behind the same value-shaped interface as the
stand-in world. Then `base_10simobj_surf_agent` becomes comparable with Monty's
own numbers.

Before that, the stand-in sensor has to earn its keep: it reports a fixed pose
and no depth, curvature or coverage, which is why `Monty.Studio.Setup` still
uses the stand-in motor rather than the ported surface policy. A world with an
object in it is what gives a surface policy something to steer by.
