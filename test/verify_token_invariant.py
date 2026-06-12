#!/usr/bin/env python3
"""verify_token_invariant.py -- pure-logic checker for the token-ring CL invariant.

The defining GLOBAL invariant of the token ring is: EXACTLY ONE token exists in
the ring at all times. A consistent Chandy-Lamport cut must therefore show the
token in EXACTLY ONE place across (node states UNION all channel states):

    (#nodes that hold the token)  +  (#TOKEN messages in flight in any channel)
    == 1

Never zero (token lost), never two (duplicate / regenerated). This holds whether
the token was RESTING in a node at the cut (one holder, every channel empty) or
IN FLIGHT between two nodes at the cut (no holder, exactly one channel carries
the token).

Inputs (no infra needed -- operates purely on the recorded artifacts):
  - artifacts: a list of per-node snapshot cut dicts, the exact shape the sidecar
    persists to /tmp/snapshot-<id>-<node>.json:
        {"snapshot_id", "node", "status": "complete"|"aborted",
         "peers": {"<peer_ip>": {"send_seq", "recv_seq",
                   "channel": [{"seq","payload_b64","src_port","dst_port",
                                "target_local_ip"}, ...]}}}
    The channel-state half of the CL cut lives in peers[*].channel: a token in
    flight is a message there whose decoded payload starts with b"TOKEN ".
  - holders: {node_id: bool} -- whether each node held the token in its OWN
    in-node state at the cut (the half CRIU captures; on the wire it is have_token
    in src/tokenring.py, surfaced via STATUS as have=1). node_id matches the
    artifact's "node" field (e.g. "tokenring-a").

The control container (mesh IP 10.24.24.200 / id "tokenring-ctl") must NEVER be
part of the recording set: it is excluded from MESH_MEMBERS, so it is neither a
recording node nor a recorded peer channel. We assert that here too.
"""

import base64
import sys

# The on-the-wire token marker. src/tokenring.py sends f"TOKEN {seq} {epoch}"
# (see node(): send_udp(next, f"TOKEN {token_seq} {epoch}")). The recorded
# channel stores that UDP payload base64-encoded in payload_b64.
TOKEN_WIRE_PREFIX = b"TOKEN "

# The control container is excluded from the snapshot recording set. Both its
# mesh IP and its container id must never appear as a recording node or a
# recorded peer channel.
CONTROL_IP = "10.24.24.200"
CONTROL_NODE_IDS = {"tokenring-ctl", "mesh-ctl"}


def _channel_token_count(artifact):
    """Number of in-flight TOKEN messages recorded in this node's channel state."""
    count = 0
    for peer in artifact.get("peers", {}).values():
        for msg in peer.get("channel", []):
            try:
                payload = base64.b64decode(msg["payload_b64"])
            except Exception as e:  # malformed artifact -- treat as a hard error
                raise ValueError(
                    f"bad payload_b64 in node {artifact.get('node')!r}: {e}"
                )
            if payload.startswith(TOKEN_WIRE_PREFIX):
                count += 1
    return count


def check_invariant(artifacts, holders):
    """Assert the exactly-one-token invariant over a set of node artifacts.

    Returns (ok: bool, detail: str). ok is True iff:
      - every artifact has status == "complete", AND
      - the control container (.200 / tokenring-ctl) is not in the recording set
        (not a recording node, not a recorded peer channel), AND
      - (#token-holding nodes) + (#in-flight TOKEN messages) == exactly 1.
    """
    if not artifacts:
        return False, "no artifacts supplied"

    # 1. Every node's cut must be a COMPLETE (consistent) Chandy-Lamport cut.
    aborted = [a.get("node") for a in artifacts if a.get("status") != "complete"]
    if aborted:
        return False, f"non-complete artifact(s): {sorted(aborted)}"

    # 2. The control container must be excluded from the recording set: it is
    #    neither a recording node nor a recorded peer channel on any node.
    for a in artifacts:
        node = a.get("node")
        if node in CONTROL_NODE_IDS:
            return False, f"control container {node!r} present as a recording node"
        for peer_ip in a.get("peers", {}):
            if peer_ip == CONTROL_IP:
                return False, (
                    f"control IP {CONTROL_IP} recorded as a peer channel on "
                    f"node {node!r} (it must be excluded from the cut)"
                )

    # 3. Count the token across (node states) UNION (all channel states).
    held_by = [a.get("node") for a in artifacts if holders.get(a.get("node"))]
    nodes_holding = len(held_by)

    inflight = 0
    inflight_on = []
    for a in artifacts:
        n = _channel_token_count(a)
        if n:
            inflight += n
            inflight_on.append((a.get("node"), n))

    total = nodes_holding + inflight
    where = []
    if held_by:
        where.append(f"held by node(s) {sorted(held_by)}")
    if inflight_on:
        where.append("in flight " + ", ".join(f"{n}x->{nd}" for nd, n in inflight_on))
    where_s = "; ".join(where) if where else "nowhere"

    if total == 1:
        return True, (
            f"exactly one token (holders={nodes_holding} inflight={inflight}); {where_s}"
        )
    if total == 0:
        return False, "token LOST: zero holders and zero in-flight (CL cut shows no token)"
    return False, (
        f"DUPLICATE token: {total} total (holders={nodes_holding} "
        f"inflight={inflight}); {where_s}"
    )


# --------------------------------------------------------------------------- #
# Self-test: synthetic artifacts, no infra. Exercises the in-flight case, the
# node-holds case, and the two negatives (zero and two tokens).
# --------------------------------------------------------------------------- #

def _b64(s):
    return base64.b64encode(s).decode("ascii")


def _node_artifact(node, channels=None, status="complete"):
    """Build a synthetic per-node cut. channels: {peer_ip: [wire_payload_bytes]}."""
    peers = {}
    for peer_ip, payloads in (channels or {}).items():
        peers[peer_ip] = {
            "send_seq": 1,
            "recv_seq": 1,
            "channel": [
                {
                    "seq": i,
                    "payload_b64": _b64(p),
                    "src_port": 5000,
                    "dst_port": 5000,
                    "target_local_ip": peer_ip,
                }
                for i, p in enumerate(payloads)
            ],
        }
    return {"snapshot_id": "selftest", "node": node, "status": status, "peers": peers}


def _selftest():
    failures = 0

    def case(name, artifacts, holders, want_ok):
        nonlocal failures
        ok, detail = check_invariant(artifacts, holders)
        verdict = "OK" if ok == want_ok else "MISMATCH"
        if ok != want_ok:
            failures += 1
        print(f"  [{verdict}] {name}: ok={ok} (want {want_ok}) -- {detail}")

    A, B, C = "tokenring-a", "tokenring-b", "tokenring-c"
    IP_A, IP_B, IP_C = "10.24.24.10", "10.24.24.11", "10.24.24.12"

    # Positive 1: token IN FLIGHT on the A->B wire (recorded in B's channel from
    # A); no node holds it. Exactly one token. THIS is the channel-state case.
    case(
        "in-flight A->B (no holder, one channel msg)",
        [
            _node_artifact(A, {IP_C: []}),
            _node_artifact(B, {IP_A: [b"TOKEN 7 3"]}),
            _node_artifact(C, {IP_B: []}),
        ],
        {A: False, B: False, C: False},
        want_ok=True,
    )

    # Positive 2: token RESTING in node B; every channel empty. Exactly one token.
    case(
        "node B holds (one holder, all channels empty)",
        [
            _node_artifact(A, {IP_C: []}),
            _node_artifact(B, {IP_A: []}),
            _node_artifact(C, {IP_B: []}),
        ],
        {A: False, B: True, C: False},
        want_ok=True,
    )

    # Negative 1: token LOST -- nobody holds it and no channel carries it.
    case(
        "zero tokens (lost)",
        [
            _node_artifact(A, {IP_C: []}),
            _node_artifact(B, {IP_A: []}),
            _node_artifact(C, {IP_B: []}),
        ],
        {A: False, B: False, C: False},
        want_ok=False,
    )

    # Negative 2: TWO tokens -- one held by A AND one in flight toward C.
    case(
        "two tokens (A holds + one in flight)",
        [
            _node_artifact(A, {IP_C: []}),
            _node_artifact(B, {IP_A: []}),
            _node_artifact(C, {IP_B: [b"TOKEN 9 4"]}),
        ],
        {A: True, B: False, C: False},
        want_ok=False,
    )

    # Negative 3: TWO tokens, both in flight (different channels).
    case(
        "two tokens (both in flight)",
        [
            _node_artifact(A, {IP_C: [b"TOKEN 1 1"]}),
            _node_artifact(B, {IP_A: [b"TOKEN 2 2"]}),
            _node_artifact(C, {IP_B: []}),
        ],
        {A: False, B: False, C: False},
        want_ok=False,
    )

    # Negative 4: a node's cut is "aborted" (inconsistent), even though token count
    # would otherwise be one.
    case(
        "aborted artifact rejected",
        [
            _node_artifact(A, {IP_C: []}),
            _node_artifact(B, {IP_A: []}, status="aborted"),
            _node_artifact(C, {IP_B: []}),
        ],
        {A: False, B: True, C: False},
        want_ok=False,
    )

    # Negative 5: the control container leaked into the recording set (as a peer
    # channel). Must be rejected even with one valid token elsewhere.
    bad = _node_artifact(A, {CONTROL_IP: [], IP_C: []})
    case(
        "control container .200 recorded as peer rejected",
        [bad, _node_artifact(B, {IP_A: []}), _node_artifact(C, {IP_B: []})],
        {A: True, B: False, C: False},
        want_ok=False,
    )

    # Non-TOKEN traffic in a channel must NOT be counted as a token (e.g. a STATUS
    # reply that happened to be in flight): token resting in A, B has a non-token
    # message in flight -> still exactly one token.
    case(
        "non-TOKEN in-flight message ignored",
        [
            _node_artifact(A, {IP_C: []}),
            _node_artifact(B, {IP_A: [b"STATUS B have=0 epoch=2 cs=1,2"]}),
            _node_artifact(C, {IP_B: []}),
        ],
        {A: True, B: False, C: False},
        want_ok=True,
    )

    print()
    if failures:
        print(f"SELF-TEST FAIL: {failures} case(s) did not match expectation")
        return 1
    print("SELF-TEST PASS: all invariant cases behaved as expected")
    return 0


def _load_artifacts(paths):
    import json
    arts = []
    for p in paths:
        with open(p) as f:
            arts.append(json.load(f))
    return arts


def main(argv):
    import argparse
    import json

    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--selftest", action="store_true",
                        help="run the no-infra synthetic self-test and exit")
    parser.add_argument("artifacts", nargs="*",
                        help="paths to /tmp/snapshot-<id>-<node>.json artifact files")
    parser.add_argument("--holds", action="append", default=[], metavar="NODE",
                        help="node id (artifact 'node' field) that holds the token "
                             "in its in-node state; repeatable")
    parser.add_argument("--holders-json", default=None, metavar="PATH",
                        help="path to a JSON {node_id: bool} map of token holders "
                             "(alternative to repeated --holds)")
    args = parser.parse_args(argv)

    if args.selftest:
        return _selftest()

    if not args.artifacts:
        parser.error("supply artifact paths, or use --selftest")

    artifacts = _load_artifacts(args.artifacts)
    holders = {}
    if args.holders_json:
        with open(args.holders_json) as f:
            holders = json.load(f)
    for n in args.holds:
        holders[n] = True

    ok, detail = check_invariant(artifacts, holders)
    print(("PASS: " if ok else "FAIL: ") + detail)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
