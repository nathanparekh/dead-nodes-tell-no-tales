#!/usr/bin/env python3
"""verify_workqueue_invariant.py -- pure-logic Chandy-Lamport conservation checker
for the work-queue app (src/workqueue.py). NO podman / CRIU / mesh required.

WHAT IT ASSERTS
---------------
A consistent global snapshot of the work queue must account for every submitted
work item EXACTLY ONCE across the union of:

  (1) NODE STATE  -- items already landed in some app's in-node state at the cut:
        * a worker that received "JOB <id>"   -> the item is assigned/in-process
          (worker.seen_job) and, once its proc delay elapses, completed
          (worker STATUS `done=<csv>`). Either way the item lives in that node.
        * (a coordinator holds no per-item state once it has dispatched -- it
          forwards-and-forgets -- so the coordinator contributes no items; we
          still accept an explicit per-node list for it, normally empty.)
  (2) CHANNEL STATE -- items still in flight toward a node at the cut, recorded
        in that node's JSON artifact under peers[peer_ip]["channel"]. Each such
        message's payload (base64) decodes to the app wire form "JOB <id>"
        (coordinator->worker) or "SUBMIT <id>" (client->coordinator). The item
        id is the token after the verb.

The invariant (derived from src/workqueue.py's own `verify`, lifted from "all
workers completed" to "no item lost or duplicated AT THE CUT"):

    multiset( node items )  +  multiset( in-flight items )  ==  set( submitted )

i.e. as a MULTISET the union has no duplicates (no item counted twice -- e.g. an
item both completed on a node AND still sitting in a channel = a double-count
the snapshot must never produce) and as a SET it equals the submitted universe
(nothing lost). This is exactly the Chandy-Lamport guarantee: node states +
channel states form one consistent cut with each item present once.

PER-ARTIFACT STRUCTURAL CHECKS
------------------------------
  * every per-node artifact has status == "complete" (an "aborted" cut is not a
    consistent global snapshot);
  * the recording/cut set EXCLUDES the control container (10.24.24.200): it is
    not a mesh member, must never appear as a node nor as a recorded peer.

USAGE (library): see verify_conservation(...) below.
USAGE (self-test, no infra):  python3 test/verify_workqueue_invariant.py --self-test
USAGE (CLI on real artifacts): python3 test/verify_workqueue_invariant.py \
        --submitted 1,2,...,N \
        --artifacts /tmp/snapshot-<id>-workqueue-a.json ... \
        --node-items workqueue-b=3,4 --node-items workqueue-c=5,6
  exit 0 = invariant holds; exit 1 = violated; prints a one-line verdict.
"""

import argparse
import base64
import json
import sys

# The app-specific control container's fixed mesh IP. It is NOT a mesh member
# (config.MESH_MEMBERS), so it must never be recorded in a cut: neither as a
# node identity nor as a peer in any node's artifact.
CONTROL_MESH_IP = "10.24.24.200"

# Wire verbs that carry a work item. Both forms appear in a recorded channel:
#   client      -> coordinator :  "SUBMIT <id>"
#   coordinator -> worker      :  "JOB <id>"
# (DONE/STATUS carry no *new* item and are not counted as item-bearing.)
ITEM_VERBS = ("JOB", "SUBMIT")


class InvariantError(Exception):
    """Raised when the exactly-once conservation invariant is violated."""


def item_from_payload(payload_bytes):
    """Decode one recorded channel payload to its work-item id, or None.

    The recorded `payload` is the raw APP payload (mesh_proxy strips the RUDP
    DATA_HEADER before process_message stores it), so it is exactly the wire
    datagram the app would have received, e.g. b"JOB 9" or b"SUBMIT 3".
    Returns the id string for an item-bearing datagram, else None (markers,
    DONE acks, STATUS, malformed).
    """
    try:
        text = payload_bytes.decode("utf-8", "replace")
    except Exception:
        return None
    parts = text.split()
    if len(parts) >= 2 and parts[0] in ITEM_VERBS:
        return parts[1]
    return None


def channel_items(artifact):
    """All in-flight work items recorded in one node's artifact (a list, so a
    genuine duplicate in-flight is visible to the multiset check)."""
    items = []
    for peer_ip, peer in artifact.get("peers", {}).items():
        for msg in peer.get("channel", []):
            payload = base64.b64decode(msg["payload_b64"])
            jid = item_from_payload(payload)
            if jid is not None:
                items.append(jid)
    return items


def _structural_checks(artifact, errors):
    """status=="complete" and control container (.200) excluded from the cut."""
    node = artifact.get("node")
    if artifact.get("status") != "complete":
        errors.append(
            f"node {node}: status is {artifact.get('status')!r}, not 'complete' "
            f"(an aborted cut is not a consistent snapshot)"
        )
    if node and CONTROL_MESH_IP in str(node):
        errors.append(
            f"control container {CONTROL_MESH_IP} appears as a recorded node "
            f"{node!r}; it must be excluded from the cut"
        )
    for peer_ip in artifact.get("peers", {}):
        if peer_ip == CONTROL_MESH_IP:
            errors.append(
                f"node {node}: control container {CONTROL_MESH_IP} appears as a "
                f"recorded peer; it must be excluded from the cut"
            )


def verify_conservation(submitted, artifacts, node_items):
    """Assert the exactly-once conservation invariant. Pure function.

    submitted : iterable of item-id strings -- the universe that was submitted.
    artifacts : list of per-node artifact dicts (the parsed
                /tmp/snapshot-<id>-workqueue-<node>.json files).
    node_items: dict {node_id: iterable of item-id strings} -- the items held
                in each app's IN-NODE state at the cut (worker assigned/
                completed; coordinator normally empty). Comes from querying each
                app's STATUS (loopback) post-cut, or from CRIU-restored state.

    Returns a dict report on success; raises InvariantError on any violation.
    """
    submitted = [str(s) for s in submitted]
    submitted_set = set(submitted)
    if len(submitted_set) != len(submitted):
        raise InvariantError("submitted universe itself contains duplicates")

    errors = []
    for art in artifacts:
        _structural_checks(art, errors)

    # Build the global multiset: node items first, then in-flight channel items.
    multiset = {}  # item -> (count, list-of-locations)
    def add(item, where):
        cnt, locs = multiset.get(item, (0, []))
        multiset[item] = (cnt + 1, locs + [where])

    for node, items in node_items.items():
        for it in items:
            add(str(it), f"node:{node}")
    for art in artifacts:
        node = art.get("node", "?")
        for it in channel_items(art):
            add(str(it), f"channel@{node}")

    # DUPLICATES: any item appearing more than once across node U channel state
    # is a double-count -- the snapshot is inconsistent.
    duplicated = {it: locs for it, (cnt, locs) in multiset.items() if cnt > 1}
    for it, locs in sorted(duplicated.items()):
        errors.append(f"item {it} counted {len(locs)}x (at {', '.join(locs)}) -- DUPLICATED")

    union = set(multiset)
    # LOST: submitted but present nowhere in the cut.
    lost = sorted(submitted_set - union)
    if lost:
        errors.append(f"items {','.join(lost)} submitted but absent from the cut -- LOST")
    # EXTRA: present in the cut but never submitted (a phantom item).
    extra = sorted(union - submitted_set)
    if extra:
        errors.append(f"items {','.join(extra)} in the cut were never submitted -- EXTRA")

    if errors:
        raise InvariantError("; ".join(errors))

    in_flight = sorted(
        it for it, (cnt, locs) in multiset.items()
        if any(l.startswith("channel@") for l in locs)
    )
    return {
        "submitted": sorted(submitted_set),
        "accounted_once": sorted(union),
        "in_flight": in_flight,
        "ok": True,
    }


# --------------------------------------------------------------------------- CLI

def _parse_artifacts(paths):
    arts = []
    for p in paths:
        with open(p) as f:
            arts.append(json.load(f))
    return arts


def _parse_node_items(specs):
    """--node-items workqueue-b=3,4  -> {"workqueue-b": ["3","4"]}"""
    out = {}
    for spec in specs:
        if "=" not in spec:
            raise SystemExit(f"--node-items must be NODE=csv, got {spec!r}")
        node, csv = spec.split("=", 1)
        out[node] = [s for s in csv.split(",") if s != ""]
    return out


# --------------------------------------------------------------------- self-test

def _b64(s):
    return base64.b64encode(s.encode()).decode("ascii")


def _channel_msg(seq, payload):
    return {"seq": seq, "payload_b64": _b64(payload),
            "src_port": 5000, "dst_port": 5000, "target_local_ip": "10.24.24.11"}


def _self_test():
    """Synthetic artifacts with NO infra: one in-flight case (passes) plus
    negative lost/duplicated/aborted/control-leak cases (must each be caught)."""
    failures = []

    def expect_ok(name, submitted, artifacts, node_items):
        try:
            rep = verify_conservation(submitted, artifacts, node_items)
            print(f"  ok  : {name} -> PASS (in_flight={rep['in_flight']})")
        except InvariantError as e:
            print(f"  FAIL: {name} -> expected PASS but got: {e}")
            failures.append(name)

    def expect_fail(name, submitted, artifacts, node_items, needle):
        try:
            verify_conservation(submitted, artifacts, node_items)
            print(f"  FAIL: {name} -> expected violation but it PASSED")
            failures.append(name)
        except InvariantError as e:
            if needle in str(e):
                print(f"  ok  : {name} -> correctly rejected ({needle})")
            else:
                print(f"  FAIL: {name} -> rejected but for the wrong reason: {e}")
                failures.append(name)

    # Topology mirrors test/test_workqueue_snapshot.sh: coordinator a, workers b/c.
    # Submitted universe 1..6. At the cut, jobs 1-4 already completed on the
    # workers (split b={1,3}, c={2,4}); jobs 5,6 were forwarded-and-forgot by the
    # coordinator and are still IN FLIGHT in the coordinator->worker channels,
    # recorded as "JOB 5"/"JOB 6" in b's and c's artifacts.
    submitted = [str(j) for j in range(1, 7)]

    art_a = {"snapshot_id": "T", "node": "workqueue-a", "status": "complete",
             "peers": {"10.24.24.11": {"send_seq": 9, "recv_seq": 2, "channel": []},
                       "10.24.24.12": {"send_seq": 8, "recv_seq": 2, "channel": []}}}
    # b's artifact: in-flight JOB 5 from the coordinator (10.24.24.10).
    art_b = {"snapshot_id": "T", "node": "workqueue-b", "status": "complete",
             "peers": {"10.24.24.10": {"send_seq": 2, "recv_seq": 5,
                                       "channel": [_channel_msg(5, "JOB 5")]}}}
    # c's artifact: in-flight JOB 6 from the coordinator.
    art_c = {"snapshot_id": "T", "node": "workqueue-c", "status": "complete",
             "peers": {"10.24.24.10": {"send_seq": 2, "recv_seq": 4,
                                       "channel": [_channel_msg(4, "JOB 6")]}}}
    good_nodes = {"workqueue-a": [], "workqueue-b": ["1", "3"], "workqueue-c": ["2", "4"]}

    # (1) happy path: 4 on nodes + 2 in flight == {1..6}, no dupes.
    expect_ok("in-flight item caught at the cut",
              submitted, [art_a, art_b, art_c], good_nodes)

    # (2) LOST: drop JOB 6 from c's channel and from node state -> item 6 vanishes.
    art_c_lost = {"snapshot_id": "T", "node": "workqueue-c", "status": "complete",
                  "peers": {"10.24.24.10": {"send_seq": 2, "recv_seq": 4, "channel": []}}}
    expect_fail("lost in-flight item (CRIU-only would lose it)",
                submitted, [art_a, art_b, art_c_lost], good_nodes, "LOST")

    # (3) DUPLICATED: JOB 5 both completed on node b AND still in b's channel.
    dup_nodes = {"workqueue-a": [], "workqueue-b": ["1", "3", "5"], "workqueue-c": ["2", "4"]}
    expect_fail("duplicated item (node + channel double-count)",
                submitted, [art_a, art_b, art_c], dup_nodes, "DUPLICATED")

    # (4) ABORTED cut: a node artifact with status != complete is not consistent.
    art_b_aborted = dict(art_b, status="aborted")
    expect_fail("aborted cut is not a consistent snapshot",
                submitted, [art_a, art_b_aborted, art_c], good_nodes, "not 'complete'")

    # (5) CONTROL LEAK: the control container .200 recorded as a peer must be caught.
    art_a_leak = json.loads(json.dumps(art_a))
    art_a_leak["peers"][CONTROL_MESH_IP] = {"send_seq": 1, "recv_seq": 1, "channel": []}
    expect_fail("control container leaked into the cut",
                submitted, [art_a_leak, art_b, art_c], good_nodes, CONTROL_MESH_IP)

    # (6) EXTRA: a phantom JOB 9 in flight that was never submitted.
    art_b_extra = {"snapshot_id": "T", "node": "workqueue-b", "status": "complete",
                   "peers": {"10.24.24.10": {"send_seq": 2, "recv_seq": 5,
                                             "channel": [_channel_msg(5, "JOB 5"),
                                                         _channel_msg(6, "JOB 9")]}}}
    expect_fail("phantom item never submitted",
                submitted, [art_a, art_b_extra, art_c], good_nodes, "EXTRA")

    if failures:
        print(f"\nINVARIANT-SELFTEST FAIL ({len(failures)} case(s): {', '.join(failures)})")
        return 1
    print("\nINVARIANT-SELFTEST PASS")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--self-test", action="store_true",
                    help="run the no-infra synthetic self-test and exit")
    ap.add_argument("--submitted", help="comma-separated submitted item universe")
    ap.add_argument("--artifacts", nargs="*", default=[],
                    help="paths to /tmp/snapshot-<id>-workqueue-<node>.json artifacts")
    ap.add_argument("--node-items", action="append", default=[], metavar="NODE=csv",
                    help="per-node in-node item ids, e.g. workqueue-b=3,4 (repeatable)")
    args = ap.parse_args()

    if args.self_test:
        sys.exit(_self_test())

    if not args.submitted or not args.artifacts:
        ap.error("real-artifact mode needs --submitted and --artifacts "
                 "(or use --self-test)")

    submitted = [s for s in args.submitted.split(",") if s != ""]
    artifacts = _parse_artifacts(args.artifacts)
    node_items = _parse_node_items(args.node_items)

    try:
        rep = verify_conservation(submitted, artifacts, node_items)
    except InvariantError as e:
        print(f"INVARIANT VIOLATED: {e}")
        sys.exit(1)
    print(f"INVARIANT OK: {len(rep['accounted_once'])} items accounted for exactly "
          f"once; in_flight at cut = [{','.join(rep['in_flight'])}]")
    sys.exit(0)


if __name__ == "__main__":
    main()
