#!/usr/bin/env python3
"""A probe for `Monty.Simulators.Port.Protocol` — not a world.

It answers the two requests the contract defines, and answers them from what it
was sent: the observation it returns carries the actions it was given, so a test
can prove the action vocabulary survived the trip. A real simulator (MuJoCo,
Habitat, a camera) replaces this file; the framing and the messages do not
change.

Framing: 4-byte big-endian length, then that many bytes of UTF-8 JSON.
"""

import json
import os
import struct
import sys

SENSOR_ID = "patch"
AGENT_ID = "agent_id_0"

# Where a test asks this probe to write down the commands it was sent. Unset in
# normal use: a world that logged to a file nobody asked for would surprise its
# caller.
LOG = os.environ.get("PROBE_WORLD_LOG")


def record(command):
    if LOG:
        with open(LOG, "a", encoding="utf-8") as log:
            log.write(command + "\n")


def read_frame(stream):
    header = stream.read(4)
    if len(header) < 4:
        return None
    (length,) = struct.unpack(">I", header)
    return stream.read(length)


def write_frame(stream, body):
    payload = json.dumps(body).encode("utf-8")
    stream.write(struct.pack(">I", len(payload)))
    stream.write(payload)
    stream.flush()


def observation(actions):
    # The "scene" is whatever was asked for: this proves the round trip, and
    # makes no claim to be geometry. It does carry a one-pixel view, because a
    # world that answers no image cannot stand behind an experiment's transforms
    # — `DepthTo3DLocations` unprojects the depth image a sensor was given.
    return {
        AGENT_ID: {
            SENSOR_ID: {
                "location": [0.0, 0.0, 0.1],
                "value": len(actions),
                "actions_seen": actions,
                "depth": [[0.1]],
                "rgba": [[[0.2, 0.7, 0.2, 1.0]]],
                "semantic": [[1.0]],
            }
        }
    }


def main(argv):
    silent = len(argv) > 1 and argv[1] == "silent"
    stream_in = sys.stdin.buffer
    stream_out = sys.stdout.buffer

    while True:
        body = read_frame(stream_in)
        if body is None:
            return 0

        if silent:
            # Read and never answer: a simulator that has died inside while its
            # process lives on.
            continue

        request = json.loads(body.decode("utf-8"))
        command = request.get("command")
        request_id = request.get("id")

        record(command)

        if command == "reset":
            write_frame(
                stream_out,
                {
                    "id": request_id,
                    "ok": True,
                    # What the episode is about, as a world that samples an object
                    # would answer it.
                    "primary_target": {
                        "object": "probe",
                        "quat_rotation": [0.0, 0.0, 0.0, 1.0],
                    },
                    # The ids the scene was built with, as Monty's own interface
                    # reports them: JSON keys are strings.
                    "semantic_id_to_label": {"1": "probe"},
                },
            )
        elif command == "step":
            write_frame(
                stream_out,
                {
                    "id": request_id,
                    "observations": observation(request.get("actions", [])),
                    "proprioceptive_state": {
                        AGENT_ID: {
                            "position": [0.0, 0.0, 0.0],
                            "rotation": [1.0, 0.0, 0.0, 0.0],
                            "sensors": {
                                SENSOR_ID: {
                                    "position": [0.0, 0.0, 0.1],
                                    "rotation": [1.0, 0.0, 0.0, 0.0],
                                }
                            },
                        }
                    },
                },
            )
        else:
            write_frame(stream_out, {"id": request_id, "error": "unknown command"})


if __name__ == "__main__":
    sys.exit(main(sys.argv))
