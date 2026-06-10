#!/usr/bin/env python3
"""Replay recorded channel state into a restored node.

Usage: python3 replay_channels.py <json_file> <target_ip>

Reads the channel dump the sidecar wrote at snapshot time
(/tmp/channel_states_<sid>.json schema) and re-sends every recorded
in-flight message, in seq order, as raw UDP to the target node.
"""
import base64
import json
import socket
import sys


def main():
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <json_file> <target_ip>", file=sys.stderr)
        return 1
    json_file, target_ip = sys.argv[1], sys.argv[2]

    try:
        with open(json_file) as f:
            data = json.load(f)
    except FileNotFoundError:
        print(f"[replay] {json_file} not found; nothing to replay")
        return 0

    channels = data.get("channels", {})
    if not channels:
        print("[replay] no recorded channels; nothing to replay")
        return 0

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    for remote_ip, msgs in channels.items():
        for msg in sorted(msgs, key=lambda m: m["seq"]):
            payload = base64.b64decode(msg["payload_b64"])
            sock.sendto(payload, (target_ip, msg["dst_port"]))
            print(f"[replay] from {remote_ip} seq={msg['seq']} "
                  f"{len(payload)} bytes -> {target_ip}:{msg['dst_port']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
