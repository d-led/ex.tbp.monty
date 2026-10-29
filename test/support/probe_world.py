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
import struct
import sys

SENSOR_ID = "patch"
AGENT_ID = "agent_id_0"


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
    # makes no claim to be geometry.
    return {
        AGENT_ID: {
            SENSOR_ID: {
                "location": [0.0, 0.0, 0.1],
                "value": len(actions),
                "actions_seen": actions,
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

        if command == "reset":
            write_frame(stream_out, {"id": request_id, "ok": True})
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
