#!/usr/bin/env python3
"""Wait until the token is in flight on the A->B wire.

Usage: python3 wait_inflight.py <a_ip> <b_ip> <port> [timeout_s=90]

Polls A and B with the app's STATUS query. Exits 0 the moment it has seen
A have=1 on some poll and then A have=0 AND B have=0 (the token left A but
has not reached B, i.e. it is sitting in the netem-delayed channel).
Exits 1 on timeout.
"""
import socket
import sys
import time


def have_token(sock, ip, port):
    """Return 0/1 from a STATUS reply, or None if the node did not answer."""
    try:
        sock.sendto(b"STATUS", (ip, port))
        reply, _ = sock.recvfrom(4096)
        for part in reply.decode().split():
            if part.startswith("have="):
                return int(part[len("have="):])
    except Exception:
        pass
    return None


def main():
    a_ip, b_ip, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
    timeout_s = float(sys.argv[4]) if len(sys.argv) > 4 else 90.0

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(0.2)

    seen_a_with_token = False
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        a = have_token(sock, a_ip, port)
        b = have_token(sock, b_ip, port)
        if a == 1:
            seen_a_with_token = True
        elif seen_a_with_token and a == 0 and b == 0:
            print(f"[wait] token in flight {a_ip} -> {b_ip}")
            return 0
        time.sleep(0.05)

    print("[wait] timed out waiting for token in flight", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
