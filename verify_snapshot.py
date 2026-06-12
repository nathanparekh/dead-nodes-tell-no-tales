#!/usr/bin/env python3
"""Verify the CONTENTS of a 6-node Chandy-Lamport snapshot cut.

Run after all six per-node JSON artifacts (written by proxy/snapshot_handler.py
and persisted via proxy/breakout_receiver.py) are collected into ONE directory.
This checks the recorded cut for completeness and consistency; it does NOT need
the CRIU images and CANNOT verify money conservation (counters live in the
images, not in these artifacts).

Usage:
  verify_snapshot.py <dir> <snapshot_id> [--members ip,ip,...]
                     [--mesh-base 10.24.24] [--min-inflight N]

Exit codes: 0 = PASS, 1 = FAIL (cut inconsistent/incomplete), 2 = usage/IO error.
"""

import argparse
import base64
import glob
import json
import os
import sys

# The six members of the 6-node test (see SPEC topology table). Last octet of
# each member IP = (ord(suffix) - ord('a')) + 10, mesh base 10.24.24.
DEFAULT_MEMBERS = [
    "10.24.24.10", "10.24.24.11", "10.24.24.12",
    "10.24.24.13", "10.24.24.14", "10.24.24.15",
]
DEFAULT_MESH_BASE = "10.24.24"


USAGE = ("usage: verify_snapshot.py <dir> <snapshot_id> [--members ip,ip,...] "
         "[--mesh-base 10.24.24] [--min-inflight N]")


def usage_error(msg):
    """Print a usage/IO error to stderr and exit 2 (never a traceback)."""
    print(f"error: {msg}", file=sys.stderr)
    print(USAGE, file=sys.stderr)
    sys.exit(2)


def node_to_ip(node, mesh_base):
    """Map a node id ("counter-a") to its mesh IP via the LAST char of the id.

    ip = <mesh_base>.<(ord(last_char) - ord('a')) + 10>. Returns None if the
    node id is missing/empty or the suffix is not a lowercase letter, so a
    malformed artifact is reported rather than crashing.
    """
    if not node:
        return None
    suffix = node[-1]
    if not ("a" <= suffix <= "z"):
        return None
    return f"{mesh_base}.{(ord(suffix) - ord('a')) + 10}"


def load_artifacts(directory, snapshot_id, mesh_base):
    """Glob + load every per-node artifact; index by mesh IP.

    Returns (by_ip, artifacts). Exits 2 on no files / unreadable / malformed
    JSON, or an artifact whose node id does not map to a mesh IP.
    """
    pattern = os.path.join(directory, f"snapshot-{snapshot_id}-counter-*.json")
    paths = sorted(glob.glob(pattern))
    if not paths:
        usage_error(f"no artifacts matched {pattern!r}; collect all six node "
                    "JSONs into one directory first")

    by_ip = {}
    artifacts = []
    for path in paths:
        try:
            with open(path) as f:
                art = json.load(f)
        except (OSError, ValueError) as e:
            usage_error(f"could not read/parse {path}: "
                        f"{type(e).__name__}: {e}")
        if not isinstance(art, dict):
            usage_error(f"{path}: top-level JSON is not an object")

        node = art.get("node")
        ip = node_to_ip(node, mesh_base)
        if ip is None:
            usage_error(f"{path}: bad/missing 'node' field {node!r}; cannot "
                        "map to a mesh IP")
        if ip in by_ip:
            usage_error(f"two artifacts map to {ip} "
                        f"(node {node!r} in {path}); duplicate node id")
        by_ip[ip] = art
        artifacts.append(art)
    return by_ip, artifacts


def check_completeness(by_ip, members):
    """Membership + per-node status. Returns (problems, complete_count)."""
    problems = []
    found = set(by_ip)
    want = set(members)

    missing = sorted(want - found)
    unexpected = sorted(found - want)
    if missing:
        problems.append(f"missing members: {', '.join(missing)}")
    if unexpected:
        problems.append(f"unexpected members: {', '.join(unexpected)}")

    complete = 0
    for ip in members:
        art = by_ip.get(ip)
        if art is None:
            continue
        status = art.get("status")
        if status == "complete":
            complete += 1
        else:
            problems.append(
                f"node {art.get('node', ip)} ({ip}) status={status!r} "
                "(expected 'complete')")
    return problems, complete


def check_channels(by_ip, members):
    """Directed-channel cut consistency over every ordered (S, R) pair.

    For each pair the sender's peers[R].send_seq must equal the receiver's
    peers[S].recv_seq, and both must be non-null. Returns (mismatches, ok_count,
    total_pairs); a missing peer entry or a null seq is reported as a mismatch,
    never a traceback.
    """
    mismatches = []
    ok = 0
    total = 0
    for s_ip in members:
        for r_ip in members:
            if s_ip == r_ip:
                continue
            total += 1
            s_art = by_ip.get(s_ip)
            r_art = by_ip.get(r_ip)
            # A whole node missing was already reported by completeness; still
            # count the pair as a mismatch so the channel tally is honest.
            s_peers = s_art.get("peers", {}) if isinstance(s_art, dict) else {}
            r_peers = r_art.get("peers", {}) if isinstance(r_art, dict) else {}
            # A peer entry may be absent OR present-but-null (peers={ip: null}):
            # `s_peers.get(r_ip, {})` returns None for a null VALUE, so coerce to
            # a dict and let a null/non-dict entry fall through to the "send is
            # None" mismatch branch instead of crashing on the chained .get().
            s_entry = s_peers.get(r_ip)
            r_entry = r_peers.get(s_ip)
            send = s_entry.get("send_seq") if isinstance(s_entry, dict) else None
            recv = r_entry.get("recv_seq") if isinstance(r_entry, dict) else None
            if send is None or recv is None or send != recv:
                mismatches.append((s_ip, r_ip, send, recv))
            else:
                ok += 1
    return mismatches, ok, total


def tally_inflight(artifacts):
    """Decode recorded in-flight channel messages across all nodes.

    Base64-decodes each payload, decodes ascii/utf-8, and classifies: a payload
    beginning "CREDIT " is parsed as `CREDIT <txid> <from> <amount>` and its
    amount added to the running credit total; anything else is "other". Returns
    (total_messages, credit_total, examples) where examples is up to 5 decoded
    payload strings. Bad base64 / non-text payloads are tolerated as "other".
    """
    total = 0
    credit_total = 0
    examples = []
    for art in artifacts:
        peers = art.get("peers", {})
        if not isinstance(peers, dict):
            continue
        for channel in (
            (p or {}).get("channel", []) for p in peers.values()
        ):
            for msg in channel or []:
                total += 1
                # A channel element could be a JSON null or a non-object in a
                # hand-edited/truncated artifact; count it but never crash.
                if not isinstance(msg, dict):
                    if len(examples) < 5:
                        examples.append("<non-object message>")
                    continue
                text = _decode_payload(msg.get("payload_b64"))
                if len(examples) < 5:
                    examples.append(text)
                if text.startswith("CREDIT "):
                    parts = text.split()
                    # CREDIT <txid> <from> <amount>
                    if len(parts) >= 4:
                        try:
                            credit_total += int(parts[3])
                        except ValueError:
                            pass  # malformed amount; counted as a message only
    return total, credit_total, examples


def _decode_payload(payload_b64):
    """Best-effort decode of a recorded payload to a printable string."""
    if not isinstance(payload_b64, str):
        return "<non-string payload>"
    try:
        raw = base64.b64decode(payload_b64)
    except (ValueError, base64.binascii.Error):
        return "<undecodable base64>"
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return f"<binary {len(raw)} bytes>"


def main():
    parser = argparse.ArgumentParser(
        description="Verify a 6-node Chandy-Lamport snapshot's recorded cut.",
        add_help=True,
    )
    parser.add_argument("dir", help="directory holding the collected "
                                    "snapshot-<id>-counter-*.json artifacts")
    parser.add_argument("snapshot_id", help="snapshot id (e.g. snap6)")
    parser.add_argument("--members", default=",".join(DEFAULT_MEMBERS),
                        help="comma-separated member IPs (default: the six "
                             "10.24.24.10..15)")
    parser.add_argument("--mesh-base", default=DEFAULT_MESH_BASE,
                        help="first three octets of the mesh subnet "
                             "(default: 10.24.24)")
    parser.add_argument("--min-inflight", type=int, default=0,
                        help="fail if fewer than N in-flight messages were "
                             "captured (default: 0 = no minimum)")

    # argparse already exits 2 on a parse error, matching our usage exit code,
    # but its default error text is fine; we just keep the same code contract.
    args = parser.parse_args()

    if not os.path.isdir(args.dir):
        usage_error(f"{args.dir!r} is not a directory")

    members = [m.strip() for m in args.members.split(",") if m.strip()]
    if not members:
        usage_error("--members resolved to an empty list")

    by_ip, artifacts = load_artifacts(args.dir, args.snapshot_id,
                                      args.mesh_base)

    # --- run the checks -----------------------------------------------------
    comp_problems, complete = check_completeness(by_ip, members)
    mismatches, ok_channels, total_channels = check_channels(by_ip, members)
    inflight_n, credit_total, examples = tally_inflight(artifacts)

    # --- report -------------------------------------------------------------
    n = len(members)
    print(f"snapshot: {args.snapshot_id}   dir: {args.dir}")
    print(f"members:  {n}  ({', '.join(members)})")
    print()

    print(f"nodes: {complete}/{n} complete")
    if comp_problems:
        for p in comp_problems:
            print(f"  PROBLEM {p}")

    print(f"channels: {ok_channels}/{total_channels} consistent")
    for s_ip, r_ip, send, recv in mismatches:
        print(f"  MISMATCH {s_ip}->{r_ip} send={send} recv={recv}")

    print(f"in-flight: {inflight_n} messages, {credit_total} total credit "
          "captured")
    for ex in examples:
        print(f"  example: {ex}")

    # --- decide PASS/FAIL ---------------------------------------------------
    reasons = []
    if comp_problems:
        reasons.append(f"{len(comp_problems)} completeness problem(s)")
    if complete != n:
        reasons.append(f"{n - complete}/{n} nodes not complete")
    if mismatches:
        reasons.append(f"{len(mismatches)} channel mismatch(es)")
    if args.min_inflight > 0 and inflight_n < args.min_inflight:
        reasons.append(
            f"only {inflight_n} in-flight messages (< --min-inflight "
            f"{args.min_inflight})")

    print()
    if reasons:
        print(f"RESULT: FAIL ({'; '.join(reasons)})")
    else:
        print("RESULT: PASS")

    # NOTE: the artifacts hold only the channel half of the cut. The per-node
    # counters live in the CRIU images, so money conservation (sum of all six
    # counters == 6 * per_node) is NOT verifiable here -- use the restore +
    # `mesh_ctl.sh sum6` capstone for that proof.
    print("NOTE: money conservation (sum of counters) is NOT checkable from "
          "these artifacts alone;\n      the counters live in the CRIU images "
          "-- use the restore + `sumn`/`sum6` capstone.")

    sys.exit(1 if reasons else 0)


if __name__ == "__main__":
    main()
