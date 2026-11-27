"""Speak to `fly_peer.py` the way `Port.Environment` does, and check it answers.

    python examples/flyverse_plugin/scripts/fly_peer_check.py

A foothold test, not an Elixir test: it proves the framing and that a Monty
action moves the body in the direction the action asked for, without starting
the application.
"""

import json
import struct
import subprocess
import sys

PEER = ["/tmp/flygym-probe/bin/python", "examples/flyverse_plugin/scripts/fly_peer.py"]
IDENTITY = [1.0, 0.0, 0.0, 0.0]


def send(process, body):
    payload = json.dumps(body).encode("utf-8")
    process.stdin.write(struct.pack(">I", len(payload)) + payload)
    process.stdin.flush()


def receive(process):
    header = process.stdout.read(4)
    assert len(header) == 4, f"the peer said nothing: {process.stderr.read() if process.poll() else 'still open'}"
    (length,) = struct.unpack(">I", header)
    return json.loads(process.stdout.read(length).decode("utf-8"))


def orient(degrees, forward_metres):
    return {
        "id": 1,
        "command": "step",
        "actions": [
            {
                "action": "orient_horizontal",
                "agent_id": "agent_id_0",
                "rotation_degrees": degrees,
                "left_distance": 0.0,
                "forward_distance": forward_metres,
            }
        ],
    }


def yaw_degrees(rotation):
    w, x, y, z = rotation
    import math

    return math.degrees(math.atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z)))


def main():
    process = subprocess.Popen(
        PEER, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd="."
    )
    try:
        send(process, {"id": 0, "command": "reset", "sensor_ids": ["left", "right"]})
        reply = receive(process)
        assert reply == {"id": 0, "ok": True}, reply
        print("reset answered", reply)

        send(process, orient(0.0, 0.005))
        reply = receive(process)
        assert reply["id"] == 1, reply
        forward = reply["proprioceptive_state"]["agent_id_0"]
        left_eye = reply["observations"]["agent_id_0"]["left"]
        print("forward 5 mm ->", [round(v, 4) for v in forward["position"]], "m")
        print("  left eye:", len(left_eye["ommatidia"]), "ommatidia x", left_eye["channels"])
        assert len(left_eye["ommatidia"]) == 721, "an eye is 721 ommatidia"
        assert abs(forward["position"][0] - 0.005) <= 0.001, (
            f"a 5 mm stride moved {forward['position'][0] * 1000:.1f} mm"
        )

        before = yaw_degrees(forward["rotation"])
        send(process, orient(25.0, 0.0))
        turned = receive(process)["proprioceptive_state"]["agent_id_0"]
        after = yaw_degrees(turned["rotation"])
        turned_degrees = after - before
        print("turn 25 deg left ->", round(turned_degrees, 1), "deg")
        assert abs(turned_degrees - 25.0) <= 5.0, f"left turn asked 25 deg, got {turned_degrees:.1f}"

        before = yaw_degrees(turned["rotation"])
        send(process, orient(-25.0, 0.0))
        turned = receive(process)["proprioceptive_state"]["agent_id_0"]
        after = yaw_degrees(turned["rotation"])
        turned_degrees = after - before
        print("turn 25 deg right ->", round(turned_degrees, 1), "deg")
        assert abs(turned_degrees + 25.0) <= 5.0, f"right turn asked -25 deg, got {turned_degrees:.1f}"
    finally:
        process.stdin.close()
        process.wait(timeout=30)


if __name__ == "__main__":
    sys.exit(main())
