#!/bin/bash
# test/test_tokenring_verify.sh -- snapshot VERIFICATION test for the token ring.
#
# Drives the ring via the app-specific control container (tokenring_ctl.sh),
# operates it normally, takes ONE Chandy-Lamport snapshot WHILE THE TOKEN IS IN
# FLIGHT on the A->B wire (so the channel-state half of the cut is exercised, not
# just node state), then VERIFIES the defining global invariant:
#
#     EXACTLY ONE token across (node states UNION all channel states).
#
# It asserts this TWO ways:
#   (1) DIRECTLY from the recorded cut: test/verify_token_invariant.py counts
#       token-holding nodes (from each restored/live node's STATUS have=) plus
#       in-flight TOKEN messages in every node's recorded channel; total must == 1.
#       It also asserts status=="complete" on every node artifact and that the
#       control container .200 is NOT in the recording set.
#   (2) END TO END: restore the WHOLE system from the snapshot (apps from their
#       CRIU images + restore-mode sidecars that replay the recorded channel),
#       then assert via the app's own STATUS that exactly one node holds the token
#       once it settles (the in-flight token is replayed into its destination, so
#       the live ring shows exactly one holder again).
#
# INFRA-GATED: full snapshot/restore needs root + podman + CRIU + the mesh
# overlay + the host breakout receiver. If any is absent this SKIPs cleanly
# (exit 0) with a clear message -- exactly like test/test_local_b.sh /
# test/test_workqueue_snapshot.sh. The pure-logic invariant checker
# (test/verify_token_invariant.py --selftest) is the part that ALWAYS runs in CI.
#
# Usage:  sudo ./test/test_tokenring_verify.sh [--deploy]
#   --deploy   bring up control + ring nodes via tokenring_ctl.sh first
#   env: A_IP/B_IP/C_IP (default .10/.11/.12), PORT (5000),
#        NETEM_MS (5000; A->B delay that holds the token in flight across the cut),
#        SETTLE_TIMEOUT (40), COLLECT_TIMEOUT (120)

set -u

A_IP=${A_IP:-10.24.24.10}; B_IP=${B_IP:-10.24.24.11}; C_IP=${C_IP:-10.24.24.12}
PORT=${PORT:-5000}
NETEM_MS=${NETEM_MS:-5000}
COLLECT_TIMEOUT=${COLLECT_TIMEOUT:-120}
SETTLE_TIMEOUT=${SETTLE_TIMEOUT:-40}
MESH_SUBNET="10.24.24.0/24"

BREAKOUT_GW=${BREAKOUT_GW:-10.99.0.1}
BREAKOUT_PORT=${BREAKOUT_PORT:-8989}
BREAKOUT_URL="http://$BREAKOUT_GW:$BREAKOUT_PORT"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKER="$ROOT/test/verify_token_invariant.py"
RESTORE_NODES="a b c"

DEPLOY=false
for arg in "$@"; do
    case "$arg" in
        --deploy) DEPLOY=true ;;
        *) echo "unknown flag: $arg (known: --deploy)" >&2; exit 2 ;;
    esac
done

skip()  { echo "SKIP: $*"; exit 0; }   # infra absent -> clean skip, never a failure
die()   { echo "FATAL: $*" >&2; exit 2; }  # harness error, distinct from a verdict (exit 1)
phase() { echo; echo "=== $* ==="; }

# --------------------------------------------------------------------- preflight gate
# The pure-logic checker ALWAYS runs (it needs no infra); the rest is gated.
phase "PRE: pure-logic invariant self-test (always runs)"
python3 "$CHECKER" --selftest || die "invariant self-test FAILED (checker is broken)"

phase "GATE: detecting infra (podman + CRIU + root + mesh + receiver)"
[ "$(id -u)" -eq 0 ] || skip "not root (podman checkpoint/restore needs CRIU as root); ran self-test only"
command -v podman >/dev/null 2>&1 || skip "podman not installed; ran self-test only"
command -v criu   >/dev/null 2>&1 || skip "criu not installed; ran self-test only"
podman network exists vlan 2>/dev/null || skip "podman network 'vlan' (mesh overlay) absent; ran self-test only"
curl -fsS --max-time 5 "$BREAKOUT_URL/health" >/dev/null 2>&1 \
    || skip "breakout receiver not answering on $BREAKOUT_URL; start it and re-run; ran self-test only"
echo "[*] infra present; running the full snapshot/restore verification."

breakout() { # synchronous POST; abort on failure
    curl -fsS --max-time 150 -X POST -H "Content-Type: application/json" \
        -d "$2" "$BREAKOUT_URL/$1" >/dev/null || die "breakout POST /$1 $2 failed"
}
breakout_ok() { # best-effort (target may already be gone)
    curl -fsS --max-time 150 -X POST -H "Content-Type: application/json" \
        -d "$2" "$BREAKOUT_URL/$1" >/dev/null \
        || echo "[!] breakout POST /$1 $2 failed; continuing (already gone?)" >&2
}

# status_loopback <suffix> -> that app's STATUS reply, read on 127.0.0.1 INSIDE the
# container. Loopback is outside MESH_SUBNET, so TPROXY never intercepts it -- this
# reads true node state with no tunnel/recording interference.
status_loopback() { podman exec "tokenring-$1" ./tokenring.py status 127.0.0.1 "$PORT" 2>/dev/null; }

# holds_token <suffix> -> 0 iff that node reports have=1 in its own state.
holds_token() { status_loopback "$1" | grep -q "have=1"; }

netem_off() { podman exec sidecar-a tc qdisc del dev eth0 root >/dev/null 2>&1 || true; }
trap 'netem_off' EXIT

# --------------------------------------------------------------------- setup
if [ "$DEPLOY" = true ]; then
    phase "SETUP: bring up control container + ring nodes via tokenring_ctl.sh"
    ( cd "$ROOT" && ./tokenring_ctl.sh nodes ) || die "ring node deploy failed"
    ( cd "$ROOT" && ./tokenring_ctl.sh up )    || die "control container up failed"
    sleep 3
else
    for c in tokenring-a tokenring-b tokenring-c sidecar-a sidecar-b sidecar-c; do
        podman container exists "$c" || die "container $c missing -- run with --deploy"
    done
fi
podman image exists sidecar || die "image 'sidecar' missing (needed for restore-mode sidecars)"

# Sanity: control container .200 + its sidecar exist and the app client path resolves.
podman exec tokenring-a test -f ./tokenring.py 2>/dev/null || die "tokenring.py not at /app in the app image"

# --------------------------------------------------------------------- operate normally
phase "OPERATE: confirm exactly one token circulates (app verify via control container)"
( cd "$ROOT" && ./tokenring_ctl.sh verify 15 ) || die "baseline ring verify FAILED -- fix the live ring first"

# --------------------------------------------------------------------- force token in flight + snapshot
phase "POSITION: hold the token IN FLIGHT on the A->B hop (netem ${NETEM_MS}ms), then snapshot"
# Delay ONLY A's traffic to B (u32 dst filter), so a token forwarded A->B sits in
# the channel long enough to be caught as channel state by the cut. A blanket
# `root netem` would also delay A's STATUS replies and snapshot markers -- which
# stalls wait_inflight (0.2s query timeout) and skews the cut. This mirrors
# harness/node_ctl.sh's netem-on (the targeted form demo_token_ring.sh uses).
podman exec sidecar-a tc qdisc add dev eth0 root handle 1: prio \
    || die "failed to add prio qdisc on sidecar-a"
podman exec sidecar-a tc qdisc add dev eth0 parent 1:3 handle 30: netem delay "${NETEM_MS}ms" \
    || die "failed to add netem class on sidecar-a"
podman exec sidecar-a tc filter add dev eth0 protocol ip parent 1: prio 1 \
    u32 match ip dst "$B_IP/32" flowid 1:3 \
    || die "failed to add A->B netem filter on sidecar-a"

echo "[*] waiting for the token to commit to the A->B wire (wait_inflight.py)"
# Run INSIDE the control container, not a bare `podman run`: only a sidecar'd
# container can speak the mesh (its sidecar de-tunnels the RUDP STATUS replies).
# A sidecar-less container's STATUS queries get no reply, so wait_inflight there
# never sees the token and always times out. Pipe the script in over stdin.
podman exec -i tokenring-ctl python3 - "$A_IP" "$B_IP" "$PORT" 90 \
    < "$ROOT/harness/wait_inflight.py" \
    || die "wait_inflight timed out -- is the ring circulating? raise NETEM_MS"

SID="vsnap$(date +%s)"
echo "[*] triggering snapshot $SID from node C (markers fan out to the static member set)"
breakout snapshot_trigger "{\"node\": \"c\", \"snapshot_id\": \"$SID\"}"

# --------------------------------------------------------------------- collect artifacts
phase "COLLECT: await each node's CRIU image + channel-state cut (/tmp/snapshot-$SID-tokenring-*)"
# B's cut waits on A's netem-delayed marker, so poll instead of racing it.
deadline=$(( $(date +%s) + COLLECT_TIMEOUT )); ready=false; prev=""
while [ "$(date +%s)" -lt "$deadline" ]; do
    ok=true
    for x in a b c; do
        [ -f "/tmp/snapshot-$SID-tokenring-$x.tar.zst" ] || ok=false
        [ -f "/tmp/snapshot-$SID-tokenring-$x.json" ]    || ok=false
    done
    if [ "$ok" = true ]; then
        sizes=$(stat -c '%s' /tmp/snapshot-"$SID"-tokenring-*.tar.zst 2>/dev/null | tr '\n' ' ')
        [ -n "$sizes" ] && [ "$sizes" = "$prev" ] && { ready=true; break; }
        prev="$sizes"
    fi
    sleep 2
done
[ "$ready" = true ] || die "timed out (${COLLECT_TIMEOUT}s) awaiting the artifact set for $SID"
netem_off
echo "[*] artifacts present:"
ls -l /tmp/snapshot-"$SID"-tokenring-*.json

# --------------------------------------------------------------------- VERIFY (1): directly from the cut
phase "VERIFY (1): exactly-one-token DIRECTLY from the recorded cut"
# Holder state half: read each node's in-node 'have' from its loopback STATUS NOW
# (the cut left the apps --leave-running, so their state still reflects the cut:
# the token left A and has not reached B, so no node holds it; it lives ONLY in
# B's recorded channel). Build the {node_id: holds} map for the checker.
HOLD_ARGS=()
echo "[*] in-node token holders at the cut (loopback STATUS):"
for x in a b c; do
    st=$(status_loopback "$x")
    echo "    tokenring-$x: ${st:-<no reply>}"
    if echo "$st" | grep -q "have=1"; then HOLD_ARGS+=(--holds "tokenring-$x"); fi
done

# Channel-state half + status==complete + control-exclusion are all asserted by
# the checker over the on-disk artifacts. Total (holders + in-flight TOKENs) must
# be exactly 1. With the token caught in flight, expect holders=0, inflight=1.
if python3 "$CHECKER" "${HOLD_ARGS[@]}" \
        "/tmp/snapshot-$SID-tokenring-a.json" \
        "/tmp/snapshot-$SID-tokenring-b.json" \
        "/tmp/snapshot-$SID-tokenring-c.json"; then
    V_CUT=PASS
else
    V_CUT=FAIL
fi
echo "[*] VERIFY (1) from-cut: $V_CUT (expected PASS: exactly one token in node-states UNION channels)"

# Diagnostic: confirm the in-flight TOKEN really is in B's channel (channel-state
# half exercised), not resting in a node (which would be a weaker test).
if python3 -c 'import json,base64,sys
d=json.load(open(sys.argv[1]))
msgs=[m for p in d.get("peers",{}).values() for m in p.get("channel",[])]
sys.exit(0 if any(base64.b64decode(m["payload_b64"]).startswith(b"TOKEN ") for m in msgs) else 1)' \
        "/tmp/snapshot-$SID-tokenring-b.json"; then
    echo "[*] channel-state exercised: the in-flight TOKEN is recorded in B's channel (CRIU cannot see it)"
else
    echo "[!] NOTE: no TOKEN in B's channel -- the token rested in a node at the cut."
    echo "[!]       The invariant still holds via node state, but channel state was not exercised."
    echo "[!]       Raise NETEM_MS (currently $NETEM_MS) to catch it on the wire."
fi

# --------------------------------------------------------------------- VERIFY (2): end-to-end restore
phase "VERIFY (2): restore the WHOLE system, replay channels, assert exactly one token live"
echo "[*] stopping sidecars then apps"
for x in $RESTORE_NODES; do
    breakout_ok stop "{\"container_id\": \"sidecar-$x\"}"
    breakout_ok stop "{\"container_id\": \"tokenring-$x\"}"
done
echo "[*] restoring apps from their CRIU images"
for x in $RESTORE_NODES; do
    breakout restore "{\"target_path\": \"/tmp/snapshot-$SID-tokenring-$x.tar.zst\"}"
done
echo "[*] letting restored apps start listening before replay"
sleep 2
echo "[*] starting restore-mode sidecars (RESTORE_SNAPSHOT_ID replays the recorded channel)"
for x in $RESTORE_NODES; do
    breakout run_sidecar "{\"node\": \"$x\", \"snapshot_id\": \"$SID\"}"
done

# After replay, the in-flight TOKEN is delivered into its destination (B), so the
# live ring once again has exactly one holder. Poll until exactly one node reports
# have=1 (and never two). Because nodes also FORWARD on their hold timer, "exactly
# one" is the steady-state invariant we assert; we accept the first poll that shows
# 1 with no poll having shown 2.
phase "SETTLE: poll loopback STATUS until exactly one node holds the token"
deadline=$(( $(date +%s) + SETTLE_TIMEOUT ))
saw_one=false; saw_two=false
while [ "$(date +%s)" -lt "$deadline" ]; do
    n=0; held=""
    for x in a b c; do
        if holds_token "$x"; then n=$((n+1)); held="$held $x"; fi
    done
    # Only judge once all three answer (a node mid-restore may be briefly silent).
    if status_loopback a >/dev/null && status_loopback b >/dev/null && status_loopback c >/dev/null; then
        echo "    holders now: count=$n [$held ]"
        [ "$n" -ge 2 ] && saw_two=true
        [ "$n" -eq 1 ] && { saw_one=true; break; }
    fi
    sleep 1
done

if [ "$saw_two" = true ]; then
    V_E2E="FAIL (saw TWO holders -> duplicate token)"
elif [ "$saw_one" = true ]; then
    V_E2E="PASS"
else
    V_E2E="FAIL (never saw exactly one holder -> token lost or restore broken)"
fi
echo "[*] VERIFY (2) end-to-end restored ring: $V_E2E (expected PASS)"

# Final app-level cross-check: the app's own verify must also pass (exactly one
# holder seen, epochs contiguous and unique) on the restored ring. Run it through
# the control container (it has a sidecar); a bare container can't read the mesh.
phase "CROSS-CHECK: app's own verify on the restored ring"
if podman exec tokenring-ctl ./tokenring.py verify 30 \
        "$A_IP" "$PORT" "$B_IP" "$PORT" "$C_IP" "$PORT"; then
    V_APP=PASS
else
    V_APP=FAIL
fi
echo "[*] app verify on restored ring: $V_APP (expected PASS)"

# --------------------------------------------------------------------- verdict
phase "VERDICT"
echo "  check                                  result   expected"
echo "  -------------------------------------  -------  --------"
echo "  (1) exactly-one-token from the cut     $V_CUT     PASS"
echo "  (2) exactly-one-token after restore    ${V_E2E%% *}     PASS  ($V_E2E)"
echo "  (x) app verify on restored ring        $V_APP     PASS"
echo
echo "  snapshot artifacts: /tmp/snapshot-$SID-tokenring-*.{json,tar.zst}"

if [ "$V_CUT" = PASS ] && [ "${V_E2E%% *}" = PASS ] && [ "$V_APP" = PASS ]; then
    echo "  RESULT: PASS (token-ring CL snapshot is consistent: exactly one token, in the cut AND after restore)"
    exit 0
fi
echo "  RESULT: FAIL"
exit 1
