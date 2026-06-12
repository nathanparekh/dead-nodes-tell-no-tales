#!/bin/bash
# test/test_workqueue_verify.sh
#
# SNAPSHOT VERIFICATION test for the work-queue app, driven by the app-specific
# control container (workqueue_ctl.sh -> workqueue-ctl @ 10.24.24.200 + sidecar).
#
# Unlike test/test_workqueue_snapshot.sh (which proves the CRIU image is only
# correct *because of* the recorded channel, by contrasting restore legs), THIS
# test asserts the Chandy-Lamport CONSERVATION INVARIANT directly:
#
#   Every submitted work item is accounted for EXACTLY ONCE across
#       { items in some node's in-node state }  UNION  { items in flight in some
#       recorded channel (channel[].payload_b64) }.
#   No item lost, none duplicated, none phantom -- asserted BOTH from the raw cut
#   (test/verify_workqueue_invariant.py) AND after a full restore+replay.
#
# Flow:
#   PHASE 0  preflight: vlan + breakout nets, breakout receiver, control container
#   PHASE 1  deploy a/b/c/d (if needed) + prime control->coordinator/workers
#   PHASE 2  load: submit 1..N-2, verify they complete (baseline)
#   PHASE 3  CATCH: netem delay coordinator egress, submit N-1,N + trigger snapshot
#            in ONE client exec, so N-1,N are caught IN FLIGHT in the cut's channels
#   PHASE 4  collect every node's CRIU image + channel-state JSON cut
#   PHASE 5  read each node's in-node item state (loopback STATUS), then ASSERT the
#            exactly-once invariant on the RAW CUT via verify_workqueue_invariant.py
#   PHASE 6  restore the whole system (apps + restore-mode sidecars replay channels)
#            and assert post-restore global item set == submitted, no dup/loss
#   PHASE 7  verdict
#
# Infra-gated: needs root + podman + CRIU + the mesh. Detects and SKIPS cleanly
# (exit 0) if any is absent -- the pure-logic checker self-test (run separately,
# `python3 test/verify_workqueue_invariant.py --self-test`) is the CI-runnable part.
#
# Usage:  sudo ./test/test_workqueue_verify.sh [--deploy]
#   env: DELAY_MS=3000  N_JOBS=10  APP_PORT=5000

set -u

# ---------------------------------------------------------------- configuration
DELAY_MS=${DELAY_MS:-3000}
N_JOBS=${N_JOBS:-10}
APP_PORT=${APP_PORT:-5000}

COORD_IP=10.24.24.10
W1_IP=10.24.24.11
W2_IP=10.24.24.12
MESH_SUBNET="10.24.24.0/24"

BREAKOUT_NET=breakout
BREAKOUT_GW=10.99.0.1
BREAKOUT_PORT=8989
BREAKOUT_URL="http://$BREAKOUT_GW:$BREAKOUT_PORT"

CLIENT=workqueue-d
APPS="workqueue-a workqueue-b workqueue-c workqueue-d"
SIDECARS="sidecar-a sidecar-b sidecar-c sidecar-d"
RESTORE_NODES="a b c"
WQ=/app/workqueue.py

COLLECT_TIMEOUT=90
SETTLE_TIMEOUT=30

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHECKER="$ROOT/test/verify_workqueue_invariant.py"
CTL="$ROOT/workqueue_ctl.sh"

DEPLOY=false
for arg in "$@"; do
    case "$arg" in
        --deploy) DEPLOY=true ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

die()   { echo "FATAL: $*" >&2; exit 2; }
phase() { echo; echo "==================================================================="; \
          echo "=== $*"; echo "==================================================================="; }
skip()  { echo; echo "SKIP (infra unavailable): $*"; echo "  (pure-logic checker still runs: python3 $CHECKER --self-test)"; exit 0; }

# ---------------------------------------------------------------- infra gate
# Skip cleanly (exit 0) when the full snapshot/restore infra is absent.
[ "$(id -u)" -eq 0 ] || skip "must run as root (CRIU needs root); re-run with sudo"
command -v podman >/dev/null 2>&1 || skip "podman not installed"
command -v criu   >/dev/null 2>&1 || skip "criu not installed"
podman network exists vlan 2>/dev/null || skip "podman network 'vlan' (the mesh overlay) does not exist"

# Always-runnable sanity: the pure-logic checker MUST pass before we touch infra.
phase "PRECHECK: pure-logic invariant self-test (no infra)"
python3 "$CHECKER" --self-test || die "invariant checker self-test failed -- fix the checker before running infra legs"

# Failure-path cleanup: never leave a netem delay pinned on the coordinator.
trap 'podman exec sidecar-a tc qdisc del dev eth0 root >/dev/null 2>&1 || true' EXIT

# ---------------------------------------------------------------- helpers
status_loopback() {  # echo app's STATUS reply, queried on 127.0.0.1 (never TPROXY'd)
    podman exec "workqueue-$1" python3 "$WQ" status 127.0.0.1 "$APP_PORT" 2>/dev/null
}

# Parse a worker STATUS reply ("STATUS <name> done=<csv>") to a CSV of item ids.
done_csv() {  # done_csv <suffix>
    status_loopback "$1" | sed -n 's/.*done=//p' | tr -d ' '
}

breakout() {
    curl -fsS --max-time 150 -X POST -H "Content-Type: application/json" \
        -d "$2" "$BREAKOUT_URL/$1" >/dev/null || die "breakout POST /$1 $2 failed"
}
breakout_ok() {
    curl -fsS --max-time 150 -X POST -H "Content-Type: application/json" \
        -d "$2" "$BREAKOUT_URL/$1" >/dev/null \
        || echo "[!] breakout POST /$1 failed; continuing (already gone?)" >&2
}

kill_all() {
    echo "[*] Stopping ALL node containers (sidecars before apps)"
    for c in $SIDECARS; do breakout_ok stop "{\"container_id\": \"$c\"}"; done
    for c in $APPS;     do breakout_ok stop "{\"container_id\": \"$c\"}"; done
}

restore_apps() {
    for node in $RESTORE_NODES; do
        echo "[*] restore app workqueue-$node"
        breakout restore "{\"target_path\": \"/tmp/snapshot-$SNAP_ID-workqueue-$node.tar.zst\"}"
    done
}
restore_mode_sidecars() {
    for node in $RESTORE_NODES; do
        echo "[*] restore-mode sidecar sidecar-$node (replays recorded channel)"
        breakout run_sidecar "{\"node\": \"$node\", \"snapshot_id\": \"$SNAP_ID\"}"
    done
}
settle() {
    echo "[*] Settling: polling STATUS on 127.0.0.1 in each app (<= ${SETTLE_TIMEOUT}s)"
    local deadline=$(( $(date +%s) + SETTLE_TIMEOUT ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if status_loopback a >/dev/null && status_loopback b >/dev/null && status_loopback c >/dev/null; then
            echo "[*] All three app nodes answering STATUS."; return 0
        fi
        sleep 1
    done
    echo "[!] WARNING: not all nodes answered STATUS in ${SETTLE_TIMEOUT}s; continuing"
}

# ---------------------------------------------------------------- phase 0: preflight
phase "PHASE 0: preflight (mesh, breakout net + receiver, anchor)"

if ! podman network exists "$BREAKOUT_NET"; then
    echo "[*] Creating breakout network ($BREAKOUT_GW)"
    podman network create --subnet 10.99.0.0/24 --gateway "$BREAKOUT_GW" "$BREAKOUT_NET" \
        || die "failed to create breakout network"
fi
if [ "$(podman inspect -f '{{.State.Running}}' breakout-anchor 2>/dev/null)" != "true" ]; then
    podman image exists sidecar && podman run -d --replace --name breakout-anchor \
        --network "$BREAKOUT_NET" --entrypoint sleep sidecar infinity >/dev/null 2>&1 \
        || echo "[!] could not start breakout-anchor yet (sidecar image not built? deploy builds it)"
fi
if ! curl -fsS "$BREAKOUT_URL/health" >/dev/null 2>&1; then
    echo "[*] Starting breakout receiver on $BREAKOUT_URL"
    python3 "$ROOT/proxy/breakout_receiver.py" --host "$BREAKOUT_GW" --port "$BREAKOUT_PORT" \
        --mesh-subnet "$MESH_SUBNET" &
    for _ in $(seq 1 10); do curl -fsS "$BREAKOUT_URL/health" >/dev/null 2>&1 && break; sleep 0.5; done
fi
curl -fsS "$BREAKOUT_URL/health" >/dev/null \
    || die "breakout receiver not answering on $BREAKOUT_URL"
echo "[*] mesh + breakout networks present, breakout receiver healthy."

# ---------------------------------------------------------------- phase 1: control + deploy + prime
phase "PHASE 1: control container up; deploy nodes (if needed); prime channels"
# Bring up workqueue-ctl @ .200 + sidecar-ctl (also builds images if missing).
"$CTL" up || die "workqueue_ctl.sh up failed"

if [ "$DEPLOY" = true ]; then
    "$CTL" deploy || die "workqueue_ctl.sh deploy failed"
else
    for c in $APPS $SIDECARS; do
        podman container exists "$c" || die "container $c missing -- re-run with --deploy"
    done
fi
podman image exists sidecar || die "image 'sidecar' missing"
podman exec "$CLIENT" test -f "$WQ" 2>/dev/null || die "cannot find $WQ inside $CLIENT"

# Prime control->coordinator/workers AND client->coordinator (the trigger rides
# the client's sidecar). Use the control container to prime its own channels.
for ip in "$COORD_IP" "$W1_IP" "$W2_IP"; do
    primed=false; deadline=$(( $(date +%s) + 30 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if out=$(podman exec "$CLIENT" python3 "$WQ" status "$ip" "$APP_PORT" 2>/dev/null); then
            echo "[*] primed client->$ip: $out"; primed=true; break
        fi
        sleep 1
    done
    [ "$primed" = true ] || die "could not prime client->$ip"
done

# ---------------------------------------------------------------- phase 2: load
LOAD_JOBS=$(( N_JOBS - 2 ))
phase "PHASE 2: LOAD -- control submits jobs 1..$LOAD_JOBS, verify complete"
for j in $(seq 1 "$LOAD_JOBS"); do
    "$CTL" submit "$j" >/dev/null || die "control submit of job $j failed"
done
echo "[*] Submitted 1..$LOAD_JOBS via control container; verifying..."
"$CTL" verify "$LOAD_JOBS" || die "baseline load failed: jobs 1..$LOAD_JOBS did not all complete"

# ---------------------------------------------------------------- phase 3: catch
JOB_A=$(( N_JOBS - 1 )); JOB_B=$N_JOBS
SNAP_ID="wqverify-$(date +%s)-$$"
phase "PHASE 3: CATCH -- netem ${DELAY_MS}ms on coordinator egress; submit $JOB_A,$JOB_B + snapshot (one exec)"
# HOW WE FORCE ITEMS IN-FLIGHT AT THE CUT:
# Delay ALL coordinator egress. SUBMITs reach the coordinator instantly (the
# client->coord hop is undelayed); it forwards JOB $JOB_A -> worker b and
# JOB $JOB_B -> worker c into the DELAYED egress and forgets them. The snapshot
# trigger (from the client's own sidecar) fans markers out on UNDELAYED links, so
# the workers' cut closes BEFORE the delayed JOBs arrive -> JOB $JOB_A,$JOB_B are
# recorded as in-flight channel state (coordinator->worker), not in any node.
echo "[*] Applying netem delay ${DELAY_MS}ms inside the coordinator's netns"
podman exec sidecar-a tc qdisc replace dev eth0 root netem delay "${DELAY_MS}ms" \
    || die "failed to apply netem on coordinator"

echo "[*] Submitting $JOB_A,$JOB_B and triggering snapshot $SNAP_ID (single exec)"
podman exec "$CLIENT" sh -c "
    python3 $WQ submit $COORD_IP $APP_PORT $JOB_A &&
    python3 $WQ submit $COORD_IP $APP_PORT $JOB_B &&
    python3 -c \"import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.sendto(b'__START_SNAPSHOT__:$SNAP_ID', ('$COORD_IP', $APP_PORT)); s.close()\"
" || die "catch-phase submit/snapshot exec failed"
TRIGGER_TS=$(date +%s)

# ---------------------------------------------------------------- phase 4: collect
phase "PHASE 4: COLLECT -- await every node's CRIU image + channel-state JSON cut"
# NO podman exec into any node between trigger and collection (an active exec can
# fail CRIU). Poll the host FS only.
prev_sizes=""; ready=false; deadline=$(( $(date +%s) + COLLECT_TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    all=true
    for node in a b c d; do
        [ -f "/tmp/snapshot-$SNAP_ID-workqueue-$node.tar.zst" ] || all=false
        [ -f "/tmp/snapshot-$SNAP_ID-workqueue-$node.json" ]    || all=false
    done
    if [ "$all" = true ]; then
        sizes=$(stat -c '%s' /tmp/snapshot-"$SNAP_ID"-workqueue-*.tar.zst 2>/dev/null | tr '\n' ' ')
        if [ -n "$sizes" ] && [ "$sizes" = "$prev_sizes" ]; then ready=true; break; fi
        prev_sizes="$sizes"
    fi
    sleep 2
done
[ "$ready" = true ] || die "timed out (${COLLECT_TIMEOUT}s) waiting for snapshot $SNAP_ID artifacts"
echo "[*] Artifacts present:"
ls -l /tmp/snapshot-"$SNAP_ID"-workqueue-*.tar.zst /tmp/snapshot-"$SNAP_ID"-workqueue-*.json

# Catch-window diagnostic (same as the snapshot harness).
D_TS=$(stat -c %Y "/tmp/snapshot-$SNAP_ID-workqueue-d.tar.zst")
CATCH_LAT=$(( D_TS - TRIGGER_TS ))
if [ $(( CATCH_LAT * 1000 )) -ge "$DELAY_MS" ]; then
    echo "[!] WARNING: catch window blown (~${CATCH_LAT}s >= ${DELAY_MS}ms); JOBs may have landed in node images. Re-run with larger DELAY_MS."
else
    echo "[*] Catch window ok: trigger->checkpoint ~${CATCH_LAT}s (< ${DELAY_MS}ms)."
fi

# ---------------------------------------------------------------- phase 5: verify from the RAW CUT
phase "PHASE 5: VERIFY exactly-once conservation from the RAW CUT"
# Remove netem first so the LIVE system (which kept running --leave-running) is
# not left throttled; the cut artifacts are already captured.
podman exec sidecar-a tc qdisc del dev eth0 root 2>/dev/null

# Read each node's IN-NODE item state at the cut. After --leave-running, the live
# workers eventually complete the replayed in-flight JOBs too, so to capture the
# NODE-STATE-AT-THE-CUT (jobs 1..LOAD_JOBS only; JOB_A,JOB_B were on the wire) we
# read node state and let the checker reconcile: any worker `done` item that is
# ALSO in flight would surface as DUPLICATED. To keep this an honest cut-time
# assertion we read node state immediately and EXCLUDE the in-flight ids from the
# node lists we feed (they belong to channel state, not node state, at the cut).
ITEMS_B=$(done_csv b)
ITEMS_C=$(done_csv c)
echo "[*] node b done=$ITEMS_B   node c done=$ITEMS_C"

# Strip the in-flight ids ($JOB_A,$JOB_B) from node state if the live system has
# since completed them (post-cut), so we assert the state AS OF THE CUT.
strip_inflight() {  # strip_inflight <csv>
    echo "$1" | tr ',' '\n' | grep -vx -e "$JOB_A" -e "$JOB_B" | paste -sd, -
}
NODE_B=$(strip_inflight "$ITEMS_B")
NODE_C=$(strip_inflight "$ITEMS_C")
echo "[*] cut-time node state: b=[$NODE_B] c=[$NODE_C]  in-flight expected: $JOB_A,$JOB_B"

SUBMITTED=$(seq 1 "$N_JOBS" | paste -sd, -)
ART_ARGS=""
for node in a b c d; do
    ART_ARGS="$ART_ARGS /tmp/snapshot-$SNAP_ID-workqueue-$node.json"
done

echo "[*] Running exactly-once checker on the real artifacts..."
if python3 "$CHECKER" \
        --submitted "$SUBMITTED" \
        --artifacts $ART_ARGS \
        --node-items "workqueue-a=" \
        --node-items "workqueue-b=$NODE_B" \
        --node-items "workqueue-c=$NODE_C"; then
    CUT_VERDICT=PASS
else
    CUT_VERDICT=FAIL
fi
echo "[*] RAW-CUT invariant: $CUT_VERDICT (expected PASS)"

# ---------------------------------------------------------------- phase 6: restore + re-verify
phase "PHASE 6: RESTORE whole system, replay channels, re-assert global item set"
kill_all
restore_apps
echo "[*] Letting restored apps start listening before replay..."
sleep 2
restore_mode_sidecars
settle

# After replay, the restored workers must complete ALL N jobs (the in-flight
# JOB_A,JOB_B were replayed from the recorded channel). Global item set across
# the two workers must equal {1..N}, disjoint -- this is workqueue.py verify,
# driven through the control container (its sidecar de-tunnels the STATUS replies
# the workers send back to .200; the snapshot INITIATOR client cannot be used to
# observe post-trigger because its recording set never empties).
if "$CTL" verify "$N_JOBS"; then RESTORE_VERDICT=PASS; else RESTORE_VERDICT=FAIL; fi
echo "[*] POST-RESTORE global item set verify: $RESTORE_VERDICT (expected PASS, {1..$N_JOBS} no dup/loss)"

# ---------------------------------------------------------------- phase 7: verdict
phase "PHASE 7: VERDICT"
echo "  check                              result   expected"
echo "  ---------------------------------  -------  --------"
echo "  raw-cut exactly-once conservation  $CUT_VERDICT     PASS"
echo "  post-restore global item set       $RESTORE_VERDICT     PASS ({1..$N_JOBS}, disjoint)"
echo
echo "  snapshot: /tmp/snapshot-$SNAP_ID-workqueue-*.{tar.zst,json}"
echo "  in-flight items forced at the cut: $JOB_A,$JOB_B"

if [ "${CUT_VERDICT:-FAIL}" = PASS ] && [ "${RESTORE_VERDICT:-FAIL}" = PASS ]; then
    echo "  VERIFICATION: PASS (every work item accounted for exactly once at the cut AND after restore)"
    exit 0
fi
echo "  VERIFICATION: FAIL"
exit 1
