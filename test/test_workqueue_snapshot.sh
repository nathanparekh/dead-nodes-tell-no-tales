#!/bin/bash
# test/test_workqueue_snapshot.sh
#
# M6 experiment driver: prove the CRIU checkpoint is only correct because of the
# proxy-recorded channel state, restored via main's ARTIFACT model
# (WORKQUEUE_PLAN.md sections 9, 11/M6).
#
# Artifact model (the ONLY restore model here):
#   - Each node's app is CRIU-checkpointed by its sidecar out-of-band:
#       /tmp/snapshot-<id>-workqueue-<node>.tar.zst   (app CRIU image)
#   - Each node's recorded Chandy-Lamport cut is persisted as a JSON artifact:
#       /tmp/snapshot-<id>-workqueue-<node>.json       (channel-state cut)
#   - Sidecars are NEVER checkpointed. Restore stops the old app+sidecar, restores
#     the app from its CRIU image, then starts a FRESH restore-mode sidecar with
#     RESTORE_SNAPSHOT_ID set; that sidecar reads GET /snapshot/<id>, seeds per-peer
#     send_seq/recv_seq, and replays the recorded channel into the local app before
#     resuming live traffic. (This is exactly what run_restore.sh / run_sidecar do.)
#
#   live continuation        -> verify PASS   (sanity: the cut did not break the live system)
#   restore (a) artifact     -> verify PASS   (apps restored + restore-mode sidecars replay the
#                                              recorded channel from the JSON artifact)
#   restore (b) CRIU-only    -> verify FAIL   (apps restored + FRESH sidecars with NO
#                                              RESTORE_SNAPSHOT_ID; the in-flight JOBs existed only
#                                              in the recorded channel state -> missing=9,10 forever)
#
# Exit 0 iff live=PASS, restore(a)=PASS, restore(b)=FAIL.
#
# !!! SINGLE-HOST ASSUMPTION (read this) !!!
# This driver assumes ALL FOUR app containers (workqueue-a .. workqueue-d) run on THIS EC2 host,
# on this host's `vlan` macvlan network, with the breakout receiver (sudo python3
# proxy/breakout_receiver.py) listening on the breakout bridge gateway 10.99.0.1:8989 and writing
# its per-node artifacts to /tmp/snapshot-<id>-workqueue-<node>.{json,tar.zst}. Multi-host
# topologies (per-node deploy + per-host receiver) are out of scope for this script. Run as root (sudo).
#
# Topology (fixed, matches build_workqueue.sh defaults):
#   a = coordinator 10.24.24.10    b = worker 10.24.24.11
#   c = worker      10.24.24.12    d = client 10.24.24.13 (sleep infinity; our exec target)
#
# Usage:
#   sudo ./test/test_workqueue_snapshot.sh [--deploy] [--criu-only]
#     --deploy     run ./build_workqueue.sh for a/b/c/d first
#     --criu-only  skip restore leg (a); run only the CRIU-only control leg (b)
#   env: DELAY_MS=3000  N_JOBS=10  APP_PORT=5000
#
# Re-runs: if a previous run aborted partway, re-run with --deploy — surviving workers retain
# completed jobs and the PHASE 2 baseline verify would fail with a confusing extra=... error.

set -u

# ---------------------------------------------------------------- configuration
DELAY_MS=${DELAY_MS:-3000}
N_JOBS=${N_JOBS:-10}
APP_PORT=${APP_PORT:-5000}

COORD_IP=10.24.24.10
W1_IP=10.24.24.11
W2_IP=10.24.24.12
MESH_SUBNET="10.24.24.0/24"

# Host-side breakout receiver (proxy/breakout_receiver.py): the sidecars POST
# /checkpoint (app CRIU image) and /snapshot_state (channel-state cut) here; it
# writes per-node artifacts to /tmp/snapshot-<id>-workqueue-<node>.{tar.zst,json}.
BREAKOUT_NET=breakout
BREAKOUT_GW=10.99.0.1
BREAKOUT_PORT=8989
BREAKOUT_URL="http://$BREAKOUT_GW:$BREAKOUT_PORT"

CLIENT=workqueue-d
APPS="workqueue-a workqueue-b workqueue-c workqueue-d"
SIDECARS="sidecar-a sidecar-b sidecar-c sidecar-d"
# The restore legs bring back only the three app-loop nodes (a/b/c); the client (d) stays dead
# (its post-cut tunnel traffic advanced seqs the restored a/b/c sidecars never saw).
RESTORE_NODES="a b c"

COLLECT_TIMEOUT=90
SETTLE_TIMEOUT=30

DEPLOY=false
CRIU_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --deploy)    DEPLOY=true ;;
        --criu-only) CRIU_ONLY=true ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

ROOT=$(cd "$(dirname "$0")/.." && pwd)

die()   { echo "FATAL: $*" >&2; exit 2; }   # exit 2 = harness error, distinct from verdict exit 1
phase() { echo; echo "==================================================================="; \
          echo "=== $*"; echo "==================================================================="; }

[ "$(id -u)" -eq 0 ] || die "must run as root (sudo): podman checkpoint/restore needs CRIU as root"

# Failure-path cleanup: a die between PHASE 3 (netem applied) and PHASE 5 (netem removed) must
# not leave a ${DELAY_MS}ms delay on the coordinator — the next run's PRIME would then fail with
# a misleading "could not prime" error. Idempotent; silent if sidecar-a or the qdisc is absent.
trap 'podman exec sidecar-a tc qdisc del dev eth0 root >/dev/null 2>&1 || true' EXIT

# ---------------------------------------------------------------- helpers
WQ=/app/workqueue.py   # path inside the workqueue image (Containerfile.workqueue: WORKDIR /app)

wq() {  # run a workqueue.py subcommand inside the mesh, via the client container
    podman exec "$CLIENT" python3 "$WQ" "$@"
}

run_verify() {  # PRE-TRIGGER ONLY: verify N against both workers over the mesh, via the client
    podman exec "$CLIENT" python3 "$WQ" verify "$1" "$W1_IP" "$APP_PORT" "$W2_IP" "$APP_PORT"
}

# ---- post-trigger observation: LOOPBACK ONLY, never through the client ----------------------
# The marker broadcast skips the channel a marker arrived on (proxy/snapshot_handler.py:
# `if peer_ip != remote_ip`), so NO node ever sends a marker back toward the snapshot INITIATOR
# — the client's own sidecar. Its recording set never empties, and it records-and-consumes every
# inbound mesh message to the client forever after the trigger, including every STATUS/verify
# reply. Observing through the client would therefore always report unreachable workers. Instead
# we exec into each APP container and query 127.0.0.1 (outside MESH_SUBNET, so TPROXY never
# intercepts it) and compute completeness/disjointness here on the host.

status_loopback() {  # status_loopback <suffix> -> echoes that app's STATUS reply
    podman exec "workqueue-$1" python3 "$WQ" status 127.0.0.1 "$APP_PORT" 2>/dev/null
}

settle() {  # after a restore, wait (up to SETTLE_TIMEOUT) until all three app nodes answer STATUS
    echo "[*] Settling: polling STATUS on 127.0.0.1 inside each app container (<= ${SETTLE_TIMEOUT}s)"
    local deadline=$(( $(date +%s) + SETTLE_TIMEOUT ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if status_loopback a >/dev/null && status_loopback b >/dev/null && status_loopback c >/dev/null; then
            echo "[*] All three app nodes answering STATUS."
            return 0
        fi
        sleep 1
    done
    echo "[!] WARNING: not all nodes answered STATUS within ${SETTLE_TIMEOUT}s; continuing (verify retries anyway)"
    return 0
}

V_REASON=""
verify_loopback() {  # verify_loopback N: 0 iff union(done(b),done(c)) == {1..N} and disjoint.
    # Host-side equivalent of workqueue.py verify (same 15s retry window, same reason strings),
    # fed by loopback STATUS instead of client-mesh STATUS. Sets V_REASON on failure.
    local n=$1
    local deadline=$(( $(date +%s) + 15 ))
    V_REASON="timeout"
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local sb sc done_b done_c all dups union missing extra
        sb=$(status_loopback b)
        sc=$(status_loopback c)
        if [ -z "$sb" ] || [ -z "$sc" ]; then
            V_REASON="unreachable workers"
        else
            done_b=$(echo "$sb" | sed -n 's/.*done=//p' | tr ',' '\n' | sed '/^$/d')
            done_c=$(echo "$sc" | sed -n 's/.*done=//p' | tr ',' '\n' | sed '/^$/d')
            all=$(printf '%s\n%s\n' "$done_b" "$done_c" | sed '/^$/d')
            dups=$(printf '%s\n' "$all" | sort -n | uniq -d | paste -sd, -)
            union=$(printf '%s\n' "$all" | sed '/^$/d' | sort -u)
            missing=$(comm -23 <(seq 1 "$n" | sort) <(printf '%s\n' "$union" | sed '/^$/d' | sort) | sort -n | paste -sd, -)
            extra=$(comm -13 <(seq 1 "$n" | sort) <(printf '%s\n' "$union" | sed '/^$/d' | sort) | sort -n | paste -sd, -)
            if [ -n "$dups" ]; then
                V_REASON="completed sets not disjoint"
            elif [ -z "$missing" ] && [ -z "$extra" ]; then
                echo "VERIFY(loopback) PASS union={1..$n} disjoint=yes"
                V_REASON=""
                return 0
            else
                V_REASON="missing=$missing extra=$extra"
            fi
        fi
        sleep 1
    done
    echo "VERIFY(loopback) FAIL $V_REASON"
    return 1
}

breakout() { # usage: breakout <endpoint> <json-body>  (synchronous; aborts on failure)
    curl -fsS --max-time 150 -X POST -H "Content-Type: application/json" \
        -d "$2" "$BREAKOUT_URL/$1" >/dev/null \
        || die "breakout POST /$1 $2 failed"
}

breakout_ok() { # best-effort variant: log and continue (target may already be gone)
    curl -fsS --max-time 150 -X POST -H "Content-Type: application/json" \
        -d "$2" "$BREAKOUT_URL/$1" >/dev/null \
        || echo "[!] breakout POST /$1 $2 failed; continuing (already gone?)" >&2
}

kill_all() {
    # Stop ALL components. Sidecar before app: a sidecar shares its app's network namespace,
    # so the app must outlive it. Tolerant of a node that is already gone.
    echo "[*] Stopping ALL containers (sidecars before apps, including the client pair)"
    for c in $SIDECARS; do breakout_ok stop "{\"container_id\": \"$c\"}"; done
    for c in $APPS;     do breakout_ok stop "{\"container_id\": \"$c\"}"; done
}

restore_apps() {
    # Restore each app-loop node (a/b/c) from its CRIU image. HOST path; the receiver owns the
    # tarball. Apps come back FIRST so the fresh/restore-mode sidecar launched next can replay
    # into an already-listening app.
    for node in $RESTORE_NODES; do
        echo "[*] restore app     workqueue-$node"
        breakout restore "{\"target_path\": \"/tmp/snapshot-$SNAP_ID-workqueue-$node.tar.zst\"}"
    done
}

restore_mode_sidecars() {
    # Leg (a): a FRESH restore-mode sidecar per node. run_sidecar sets RESTORE_SNAPSHOT_ID, so
    # each sidecar reads GET /snapshot/<id>, seeds per-peer send_seq/recv_seq from the JSON
    # artifact, replays the recorded channel into the local app once in seq order, then resumes.
    for node in $RESTORE_NODES; do
        echo "[*] restore-mode sidecar sidecar-$node (replays recorded channel)"
        breakout run_sidecar "{\"node\": \"$node\", \"snapshot_id\": \"$SNAP_ID\"}"
    done
}

fresh_sidecars() {
    # Leg (b) control: brand-new sidecars exactly as the deploy script launches them — NO
    # RESTORE_SNAPSHOT_ID, so the recorded channel artifact is never read. All recorded channel
    # state (the in-flight JOBs) is discarded; fresh sidecars re-handshake from seq 0 so plain
    # traffic still flows, but the lost JOBs are gone forever.
    for node in $RESTORE_NODES; do
        echo "[*] fresh sidecar   sidecar-$node (no replay)"
        podman run -d --replace \
            --name "sidecar-$node" \
            --network "container:workqueue-$node" \
            --cap-add NET_ADMIN \
            --sysctl net.ipv4.ip_nonlocal_bind=1 \
            -e MESH_SUBNET="$MESH_SUBNET" \
            -e BREAKOUT_URL="$BREAKOUT_URL" \
            -e CHECKPOINT_TARGET="workqueue-$node" \
            sidecar >/dev/null || die "failed to launch fresh sidecar-$node"
    done
}

# ---------------------------------------------------------------- phase 0: preflight
phase "PHASE 0: preflight"

podman network exists vlan || die "podman network 'vlan' does not exist (create the macvlan network first)"

# The breakout bridge must exist before the receiver can bind its gateway and
# before --deploy attaches it to the app containers.
if ! podman network exists "$BREAKOUT_NET"; then
    echo "[*] Creating breakout network ($BREAKOUT_GW)"
    podman network create --subnet 10.99.0.0/24 --gateway "$BREAKOUT_GW" "$BREAKOUT_NET" \
        || die "failed to create breakout network"
fi

# Keep a tiny anchor on the breakout bridge so podman keeps 10.99.0.1 up even after restore stops
# every app — otherwise the receiver "listens" via IP_FREEBIND on an address nothing can route to.
if [ "$(podman inspect -f '{{.State.Running}}' breakout-anchor 2>/dev/null)" != "true" ]; then
    echo "[*] Starting breakout-anchor (keeps 10.99.0.1 up across restore)"
    podman image exists sidecar && podman run -d --replace --name breakout-anchor \
        --network "$BREAKOUT_NET" --entrypoint sleep sidecar infinity >/dev/null 2>&1 \
        || echo "[!] could not start breakout-anchor yet (sidecar image not built? deploy will build it)"
fi

# Start the host-side breakout receiver if it isn't already answering. It binds
# the breakout gateway with IP_FREEBIND, so it can come up before any container
# attaches the bridge.
if ! curl -fsS "$BREAKOUT_URL/health" >/dev/null 2>&1; then
    echo "[*] Starting breakout receiver on $BREAKOUT_URL"
    python3 "$ROOT/proxy/breakout_receiver.py" --host "$BREAKOUT_GW" --port "$BREAKOUT_PORT" \
        --mesh-subnet "$MESH_SUBNET" &
    for _ in $(seq 1 10); do
        curl -fsS "$BREAKOUT_URL/health" >/dev/null 2>&1 && break
        sleep 0.5
    done
fi
curl -fsS "$BREAKOUT_URL/health" >/dev/null \
    || die "breakout receiver not answering on $BREAKOUT_URL — run: sudo python3 $ROOT/proxy/breakout_receiver.py --host $BREAKOUT_GW --port $BREAKOUT_PORT --mesh-subnet $MESH_SUBNET"
echo "[*] vlan + breakout networks present, breakout receiver healthy."

if [ "$DEPLOY" = true ]; then
    echo "[*] --deploy: building and launching a=coordinator b=worker c=worker d=client"
    cd "$ROOT" || die "cannot cd to $ROOT"
    ./build_workqueue.sh a coordinator || die "deploy of node a failed"
    ./build_workqueue.sh b worker      || die "deploy of node b failed"
    ./build_workqueue.sh c worker      || die "deploy of node c failed"
    ./build_workqueue.sh d client      || die "deploy of node d failed"
    echo "[*] Letting sidecars finish TPROXY setup..."
    sleep 3
else
    for c in $APPS $SIDECARS; do
        podman container exists "$c" || die "container $c missing — run with --deploy (or deploy manually)"
    done
fi
podman image exists sidecar || die "image 'sidecar' missing (needed for restore-mode + fresh sidecars)"

# Sanity-check the app path inside the client image (Containerfile may evolve).
if ! podman exec "$CLIENT" test -f "$WQ" 2>/dev/null; then
    WQ=$(podman exec "$CLIENT" sh -c "find / -maxdepth 3 -name workqueue.py 2>/dev/null | head -n1")
    [ -n "$WQ" ] || die "cannot locate workqueue.py inside $CLIENT"
    echo "[*] workqueue.py found at $WQ inside $CLIENT"
fi

# ---------------------------------------------------------------- phase 1: prime
phase "PHASE 1: PRIME — client warms a channel to coordinator AND both workers BEFORE the snapshot"
# Snapshot membership is STATIC now (proxy/snapshot_handler.py derives the cut from MESH_MEMBERS,
# not a lazily-discovered peer set), so every member is marked/recorded even if never warmed —
# priming is no longer required to avoid a silently-omitted node. We still prime for TIMING: it
# forces every node's first marker to arrive on an UNDELAYED client channel (and establishes the
# tunnels so the very first SUBMIT/JOB does not pay the probe-handshake latency in PHASE 3).

for ip in "$COORD_IP" "$W1_IP" "$W2_IP"; do
    primed=false
    deadline=$(( $(date +%s) + 30 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if out=$(wq status "$ip" "$APP_PORT" 2>/dev/null); then
            echo "[*] primed $ip: $out"
            primed=true
            break
        fi
        sleep 1   # first packet rides the sidecar probe handshake; retry until tunneled
    done
    [ "$primed" = true ] || die "could not prime client<->$ip channel (no STATUS reply in 30s)"
done

# ---------------------------------------------------------------- phase 2: load
LOAD_JOBS=$(( N_JOBS - 2 ))
phase "PHASE 2: LOAD — submit jobs 1..$LOAD_JOBS and verify them complete"

for j in $(seq 1 "$LOAD_JOBS"); do
    wq submit "$COORD_IP" "$APP_PORT" "$j" || die "submit of job $j failed"
done
echo "[*] Submitted jobs 1..$LOAD_JOBS; verifying..."
run_verify "$LOAD_JOBS" || die "baseline load failed: jobs 1..$LOAD_JOBS did not all complete"

# ---------------------------------------------------------------- phase 3: catch
JOB_A=$(( N_JOBS - 1 ))
JOB_B=$N_JOBS
phase "PHASE 3: CATCH — netem ${DELAY_MS}ms on coordinator egress, then submit $JOB_A,$JOB_B + snapshot in ONE exec"

# We choose the snapshot id ourselves (vs letting the initiating sidecar mint a random UUID for a
# bare __START_SNAPSHOT__) so the harness knows which /tmp/snapshot-<id>-* artifacts to await and
# restore. The sidecar's __START_SNAPSHOT__:<id> intercept path honours an explicit id.
SNAP_ID="wqsnap-$(date +%s)-$$"

# Delay ALL coordinator egress (JOBs to workers ride this; client->coord SUBMITs do not).
echo "[*] Applying netem delay ${DELAY_MS}ms inside the coordinator's netns"
podman exec sidecar-a tc qdisc replace dev eth0 root netem delay "${DELAY_MS}ms" \
    || die "failed to apply netem on coordinator (sidecar-a)"

# ONE exec, minimal gap between the last SUBMITs and the trigger:
#   - SUBMITs reach the coordinator app instantly (client->coord hop is undelayed); it forwards
#     JOB $JOB_A -> worker b and JOB $JOB_B -> worker c (round-robin) into the delayed egress and
#     FORGETS them. Both JOBs now exist only in netem flight + the coordinator sidecar's unacked
#     buffer (ACKs cannot return before the cut).
#   - The snapshot trigger never leaves the client: its own sidecar intercepts
#     __START_SNAPSHOT__:<id>, checkpoints the client's app FIRST, then fans markers out on
#     undelayed links. Tunnel FIFO guarantees the coordinator sees SUBMITs strictly before the
#     client's marker.
echo "[*] Submitting jobs $JOB_A,$JOB_B and triggering snapshot $SNAP_ID (single exec)"
podman exec "$CLIENT" sh -c "
    python3 $WQ submit $COORD_IP $APP_PORT $JOB_A &&
    python3 $WQ submit $COORD_IP $APP_PORT $JOB_B &&
    python3 -c \"import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.sendto(b'__START_SNAPSHOT__:$SNAP_ID', ('$COORD_IP', $APP_PORT)); s.close()\"
" || die "catch-phase submit/snapshot exec failed"
TRIGGER_TS=$(date +%s)   # the trigger send is fire-and-forget and last in the exec: ~trigger instant

# ---------------------------------------------------------------- phase 4: collect
phase "PHASE 4: COLLECT — wait for every node's CRIU image + channel-state cut to land"
# NOTE: no podman exec into any node between the trigger and collection completing — an active
# exec session can make CRIU's checkpoint of that container fail. We only poll the host FS here.
# Artifact model: each node writes BOTH /tmp/snapshot-<id>-workqueue-<node>.tar.zst (app image)
# and /tmp/snapshot-<id>-workqueue-<node>.json (recorded channel cut). The 4 app-loop/client
# nodes a..d each produce a .tar.zst; a..c plus the client produce a .json (every node that
# received a marker writes one). We require all four CRIU images and all four cut jsons, sizes
# stable across two polls so we never grab a half-written export.
prev_sizes=""
ready=false
deadline=$(( $(date +%s) + COLLECT_TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    all_present=true
    for node in a b c d; do
        [ -f "/tmp/snapshot-$SNAP_ID-workqueue-$node.tar.zst" ] || all_present=false
        [ -f "/tmp/snapshot-$SNAP_ID-workqueue-$node.json" ]    || all_present=false
    done
    if [ "$all_present" = true ]; then
        sizes=$(stat -c '%s' /tmp/snapshot-"$SNAP_ID"-workqueue-*.tar.zst 2>/dev/null | tr '\n' ' ')
        if [ -n "$sizes" ] && [ "$sizes" = "$prev_sizes" ]; then
            ready=true
            break
        fi
        prev_sizes="$sizes"
    fi
    sleep 2
done
[ "$ready" = true ] || die "timed out (${COLLECT_TIMEOUT}s) waiting for all CRIU images + cut jsons of snapshot $SNAP_ID"
echo "[*] Snapshot $SNAP_ID artifacts present:"
ls -l /tmp/snapshot-"$SNAP_ID"-workqueue-*.tar.zst /tmp/snapshot-"$SNAP_ID"-workqueue-*.json

# Catch-window check (diagnostic). Markers fan out only AFTER the initiator's blocking checkpoint
# call returns, i.e. after the client's app CRIU export finished — approximated by the mtime of
# the client's image. If trigger->fan-out took >= DELAY_MS, JOBs $JOB_A,$JOB_B reached the LIVE
# workers before their cut, landed inside the worker images, and leg (b) would "pass" for the
# wrong reason: report that as a blown catch window so the verdict is diagnosable.
CATCH=OK
D_TS=$(stat -c %Y "/tmp/snapshot-$SNAP_ID-workqueue-d.tar.zst")
CATCH_LAT=$(( D_TS - TRIGGER_TS ))
if [ $(( CATCH_LAT * 1000 )) -ge "$DELAY_MS" ]; then
    CATCH=BLOWN
    echo "[!] WARNING: catch window blown: trigger->checkpoint ~${CATCH_LAT}s >= DELAY_MS=${DELAY_MS}ms"
    echo "[!]          Re-run with e.g. DELAY_MS=$(( DELAY_MS * 2 ))."
else
    echo "[*] Catch window ok: trigger->checkpoint ~${CATCH_LAT}s (< DELAY_MS=${DELAY_MS}ms)."
fi

# ---------------------------------------------------------------- phase 5: live continuation
phase "PHASE 5: LIVE — remove netem, sanity-verify the live system completes all $N_JOBS jobs"
# After each checkpoint call returned, the live system kept going (--leave-running): markers
# closed the channels and recorded in-flight JOBs were replayed into the LIVE apps. This proves
# the cut itself broke nothing; both restore legs below start from the same images regardless.

podman exec sidecar-a tc qdisc del dev eth0 root 2>/dev/null
# Loopback verify: post-trigger, the client's sidecar (the initiator) never receives a marker
# back and consumes every mesh reply to the client — client-mesh verify would hang (see helpers).
if verify_loopback "$N_JOBS"; then LIVE=PASS; else LIVE=FAIL; fi
echo "[*] live continuation verify: $LIVE (expected PASS)"

# ---------------------------------------------------------------- phase 6: restore leg (a)
if [ "$CRIU_ONLY" = true ]; then
    phase "PHASE 6: RESTORE (a) — SKIPPED (--criu-only)"
    RES_A=SKIP
else
    phase "PHASE 6: RESTORE (a) ARTIFACT — stop all, restore apps, then restore-mode sidecars replay the cut"
    # Each restore-mode sidecar (RESTORE_SNAPSHOT_ID set) reads its node's JSON cut from
    # GET /snapshot/<id>, seeds per-peer send_seq/recv_seq, and replays the recorded in-flight
    # JOBs into its restored app. With the channel artifact in hand, the workers recover the
    # JOBs the coordinator forwarded-and-forgot.
    kill_all
    restore_apps            # apps FIRST (see restore_apps comment)
    echo "[*] Letting restored apps start listening before replay..."
    sleep 2
    restore_mode_sidecars
    settle
    if verify_loopback "$N_JOBS"; then RES_A=PASS; else RES_A=FAIL; fi
    echo "[*] restore (a) verify: $RES_A (expected PASS)"
fi

# ---------------------------------------------------------------- phase 7: restore leg (b)
phase "PHASE 7: RESTORE (b) CONTROL — same app images, FRESH sidecars (channel artifact discarded)"
# This is what a naive CRIU-only checkpoint yields. JOBs $JOB_A,$JOB_B exist in NO app image
# (the coordinator forwarded-and-forgot; the workers never received them) and the recorded
# channel artifact is never read (fresh sidecars have no RESTORE_SNAPSHOT_ID). The coordinator
# has no dispatch log to recover from.

kill_all
restore_apps            # ONLY the app containers, from the SAME images
fresh_sidecars
echo "[*] Letting fresh sidecars finish TPROXY setup..."
sleep 3                 # mirror the deploy path, so an unreachable app is never just TPROXY lag
settle
if verify_loopback "$N_JOBS"; then RES_B=PASS; else RES_B=FAIL; fi
B_DETAIL="$V_REASON"
echo "[*] restore (b) verify: $RES_B ${B_DETAIL:+($B_DETAIL)} (expected FAIL missing=$JOB_A,$JOB_B extra=)"

# ---------------------------------------------------------------- phase 8: verdict
phase "PHASE 8: VERDICT"
echo "  leg                          result   expected"
echo "  ---------------------------  -------  --------"
echo "  catch window                 $CATCH       OK (trigger->checkpoint ${CATCH_LAT}s, DELAY_MS=${DELAY_MS})"
echo "  live continuation            $LIVE     PASS"
echo "  restore (a) artifact-replay  $RES_A     PASS"
echo "  restore (b) CRIU-only        $RES_B     FAIL missing=$JOB_A,$JOB_B ${B_DETAIL:+ (got: $B_DETAIL)}"
echo
echo "  snapshot artifacts: /tmp/snapshot-$SNAP_ID-workqueue-*.{tar.zst,json}"

# Leg (b) only demonstrates the property when it fails for EXACTLY the right reason: the two
# in-flight jobs missing and nothing else. Verify also exits non-zero for unreachable workers
# or non-disjoint sets — broken restore plumbing that must NOT count as experiment success.
B_AS_EXPECTED=false
if [ "$RES_B" = FAIL ] && [ "$B_DETAIL" = "missing=$JOB_A,$JOB_B extra=" ]; then
    B_AS_EXPECTED=true
fi

if [ "$CRIU_ONLY" = true ]; then
    if [ "$LIVE" = PASS ] && [ "$B_AS_EXPECTED" = true ]; then
        echo "  EXPERIMENT: PASS (criu-only mode: live ok, CRIU-only control lost exactly the in-flight jobs)"
        exit 0
    fi
else
    if [ "$LIVE" = PASS ] && [ "$RES_A" = PASS ] && [ "$B_AS_EXPECTED" = true ]; then
        echo "  EXPERIMENT: PASS (checkpoint correctness demonstrably depends on the proxy-recorded channel artifact)"
        exit 0
    fi
fi
if [ "$RES_B" = FAIL ] && [ "$B_AS_EXPECTED" = false ]; then
    echo "  NOTE: leg (b) failed, but not with the expected 'missing=$JOB_A,$JOB_B extra=' (got: ${B_DETAIL:-none})"
    echo "        — that is broken restore plumbing, not the lost-in-flight-jobs property."
fi
if [ "$CATCH" = BLOWN ]; then
    echo "  NOTE: the catch window was blown — if leg (b) passed, the JOBs were cut INTO the worker"
    echo "        images instead of being caught on the wire. Re-run with a larger DELAY_MS."
fi
echo "  EXPERIMENT: FAIL"
exit 1
