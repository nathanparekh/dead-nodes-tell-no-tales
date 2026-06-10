#!/bin/bash
# test/test_workqueue_snapshot.sh
#
# M6 experiment driver: prove the CRIU checkpoint is only correct because of the
# proxy-recorded channel state (WORKQUEUE_PLAN.md sections 9, 11/M6).
#
#   live continuation        -> verify PASS   (sanity: the cut did not break the live system)
#   restore (a) full images  -> verify PASS   (apps + sidecars from the same cut; channel replayed)
#   restore (b) CRIU-only    -> verify FAIL   (apps from the same cut + FRESH sidecars; the
#                                              in-flight JOBs existed only in the discarded
#                                              sidecar state -> missing=9,10 forever)
#
# Exit 0 iff live=PASS, restore(a)=PASS, restore(b)=FAIL.
#
# !!! SINGLE-HOST ASSUMPTION (read this) !!!
# This driver assumes ALL FOUR node pairs (workqueue-a/sidecar-a .. workqueue-d/sidecar-d)
# run on THIS EC2 host, on this host's `vlan` macvlan network, with the checkpoint agent
# (sudo python3 checkpoint_agent.py) listening on localhost:9090 and exporting to
# /tmp/snapshots/. Multi-host topologies (per-node deploy + per-host agent) are out of scope
# for this script. Run as root (sudo).
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

CLIENT=workqueue-d
APPS="workqueue-a workqueue-b workqueue-c workqueue-d"
SIDECARS="sidecar-a sidecar-b sidecar-c sidecar-d"

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
# — the client's own sidecar. Its recording set {a,b,c} never empties, and it records-and-
# consumes every inbound mesh message to the client forever after the trigger, including every
# STATUS/verify reply. Observing through the client would therefore always report unreachable
# workers. Instead we exec into each APP container and query 127.0.0.1 (outside MESH_SUBNET, so
# TPROXY never intercepts it) and compute completeness/disjointness here on the host.

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

kill_all() {
    # Kill ALL EIGHT containers — apps AND sidecars, INCLUDING THE CLIENT PAIR.
    # The client pair must die (and later be restored from its cut images) because its live
    # post-cut tunnel traffic advanced sequence numbers the restored a/b/c sidecars never saw;
    # a surviving (or fresh) client would wedge in the strict in-order receive buffers.
    echo "[*] Killing ALL EIGHT containers (apps + sidecars, including the client pair)"
    podman rm -f $SIDECARS >/dev/null 2>&1
    podman rm -f $APPS     >/dev/null 2>&1
}

restore_apps() {
    # LOAD-BEARING ORDER: ALL app containers first, THEN sidecars (restore_sidecars below).
    # A restored sidecar immediately resumes its broken checkpoint-agent call, hits the except
    # branch, broadcasts markers and (once channels close) replays recorded in-flight messages
    # into the local app by spoofed delivery — if the app weren't restored yet, that delivery
    # would be lost and the experiment void.
    for c in $APPS; do
        echo "[*] restore app     $c"
        podman container restore --tcp-established --import "$RUN_DIR/$c.tar.zst" >/dev/null \
            || die "restore of $c failed"
    done
}

restore_sidecars() {
    for c in $SIDECARS; do
        echo "[*] restore sidecar $c"
        podman container restore --tcp-established --import "$RUN_DIR/$c.tar.zst" >/dev/null \
            || die "restore of $c failed"
    done
}

fresh_sidecars() {
    # Leg (b) control: brand-new sidecars exactly as the deploy script launches them.
    # All recorded channel state (the in-flight JOBs) and all tunnel seq state dies with the
    # old sidecars; fresh-vs-fresh sidecars re-handshake from seq 0 so plain traffic still flows.
    for x in a b c d; do
        echo "[*] fresh sidecar   sidecar-$x"
        podman run -d --replace \
            --name "sidecar-$x" \
            --network "container:workqueue-$x" \
            --cap-add NET_ADMIN \
            --sysctl net.ipv4.ip_nonlocal_bind=1 \
            -e MESH_SUBNET="$MESH_SUBNET" \
            sidecar >/dev/null || die "failed to launch fresh sidecar-$x"
    done
}

# ---------------------------------------------------------------- phase 0: preflight
phase "PHASE 0: preflight"

podman network exists vlan || die "podman network 'vlan' does not exist (create the macvlan network first)"
curl -fsS http://localhost:9090/health >/dev/null \
    || die "checkpoint agent not answering on localhost:9090 — run: sudo python3 $ROOT/checkpoint_agent.py"
echo "[*] vlan network present, checkpoint agent healthy."

# Proxy prerequisite gate (checks the SOURCE tree; rebuild images via --deploy after porting).
# The experiment timeline is impossible on the unported snapshot handler: it broadcasts markers
# with a 9-byte !BIHH header while the tunnel parses the 17-byte !BQHH4s data header, so
# receivers never recognize a marker, only the client pair ever checkpoints, and PHASE 4 would
# always time out; its replay path also calls process_and_deliver without target_local_ip
# (TypeError). Both are fixed by the snapshot-handler port on branch bug-hunt-claude-screen
# (commit aa6fc62) — refuse to run until that lands here.
SH_SRC="$ROOT/proxy/snapshot_handler.py"
[ -f "$SH_SRC" ] || die "proxy source not found: $SH_SRC"
if grep -q '!BIHH' "$SH_SRC"; then
    die "proxy prerequisite missing: $SH_SRC still packs markers with the 9-byte !BIHH header — port the snapshot-handler framing fix (branch bug-hunt-claude-screen, commit aa6fc62) onto this branch, then re-run with --deploy"
fi
if ! grep -q 'target_local_ip' "$SH_SRC"; then
    die "proxy prerequisite missing: $SH_SRC replay still calls process_and_deliver without target_local_ip — port commit aa6fc62 (bug-hunt-claude-screen) onto this branch, then re-run with --deploy"
fi
echo "[*] proxy snapshot-handler framing/replay port detected."
echo "[!] NOTE: proxy bug S7 (recorded in-flight messages dropped at replay because recv_seq"
echo "[!]       already advanced; claude_screen/findings/11-snapshot-divergence.md) cannot be"
echo "[!]       detected statically. If LIVE and RESTORE(a) below FAIL with missing=$(( N_JOBS - 1 )),$N_JOBS,"
echo "[!]       S7 is still open in the proxy — that is a proxy bug, not a harness bug."

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
podman image exists sidecar || die "image 'sidecar' missing (needed for leg (b) fresh sidecars)"

# Sanity-check the app path inside the client image (Containerfile may evolve).
if ! podman exec "$CLIENT" test -f "$WQ" 2>/dev/null; then
    WQ=$(podman exec "$CLIENT" sh -c "find / -maxdepth 3 -name workqueue.py 2>/dev/null | head -n1")
    [ -n "$WQ" ] || die "cannot locate workqueue.py inside $CLIENT"
    echo "[*] workqueue.py found at $WQ inside $CLIENT"
fi

# ---------------------------------------------------------------- phase 1: prime
phase "PHASE 1: PRIME — client talks to coordinator AND both workers BEFORE the snapshot"
# LOAD-BEARING. The snapshot initiator is the CLIENT's sidecar, and it broadcasts markers only
# to peers it has already tunneled with (self.proxy.peers — created on first traffic). If the
# client never talked to a worker, that worker's FIRST marker would arrive from the coordinator,
# FIFO-behind the in-flight JOB on the netem-delayed channel — the worker would checkpoint
# AFTER receiving the JOB, the JOB would be inside the CRIU image, and leg (b) would not fail.
# Priming guarantees every node's first marker arrives on an UNDELAYED client channel.

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

# Delay ALL coordinator egress (JOBs to workers ride this; client->coord SUBMITs do not).
echo "[*] Applying netem delay ${DELAY_MS}ms inside the coordinator's netns"
podman exec sidecar-a tc qdisc replace dev eth0 root netem delay "${DELAY_MS}ms" \
    || die "failed to apply netem on coordinator (sidecar-a)"

# ONE exec, minimal gap between the last SUBMITs and the trigger:
#   - SUBMITs reach the coordinator app instantly (client->coord hop is undelayed); it forwards
#     JOB $JOB_A -> worker b and JOB $JOB_B -> worker c (round-robin) into the delayed egress and
#     FORGETS them. Both JOBs now exist only in netem flight + the coordinator sidecar's unacked
#     buffer (ACKs cannot return before the cut).
#   - The snapshot trigger never leaves the client: its own sidecar intercepts __START_SNAPSHOT__,
#     checkpoints the client pair FIRST, then fans markers out on undelayed links. Tunnel FIFO
#     guarantees the coordinator sees SUBMITs strictly before the client's marker.
# Staleness guard: remember what /tmp/snapshots/latest points at NOW. On a re-run it still
# names the PREVIOUS run's complete 8-tar directory, which would otherwise satisfy the PHASE 4
# checks within ~2 polls — long before this run's first export lands — and the harness would
# restore last run's cut while this run is still checkpointing.
PRE_LATEST=$(readlink -f /tmp/snapshots/latest 2>/dev/null || true)

echo "[*] Submitting jobs $JOB_A,$JOB_B and triggering the snapshot (single exec)"
podman exec "$CLIENT" sh -c "
    python3 $WQ submit $COORD_IP $APP_PORT $JOB_A &&
    python3 $WQ submit $COORD_IP $APP_PORT $JOB_B &&
    python3 $WQ snapshot $COORD_IP $APP_PORT
" || die "catch-phase submit/snapshot exec failed"
TRIGGER_TS=$(date +%s)   # the trigger send is fire-and-forget and last in the exec: ~trigger instant

# ---------------------------------------------------------------- phase 4: collect
phase "PHASE 4: COLLECT — wait for all 8 checkpoint exports"
# NOTE: no podman exec into any node between the trigger and collection completing — an active
# exec session can make CRIU's checkpoint of that container fail. We only poll the host FS here.

SNAP_DIR=""
prev_sizes=""
deadline=$(( $(date +%s) + COLLECT_TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -e /tmp/snapshots/latest ]; then
        dir=$(readlink -f /tmp/snapshots/latest)
        if [ "$dir" != "$PRE_LATEST" ]; then   # ignore a stale 'latest' from a previous run
            all_present=true
            for c in $APPS $SIDECARS; do
                [ -f "$dir/$c.tar.zst" ] || all_present=false
            done
            if [ "$all_present" = true ]; then
                # require sizes stable across two polls so we never grab a half-written export
                sizes=$(stat -c '%s' "$dir"/*.tar.zst 2>/dev/null | tr '\n' ' ')
                if [ -n "$sizes" ] && [ "$sizes" = "$prev_sizes" ]; then
                    SNAP_DIR="$dir"
                    break
                fi
                prev_sizes="$sizes"
            fi
        fi
    fi
    sleep 2
done
[ -n "$SNAP_DIR" ] || die "timed out (${COLLECT_TIMEOUT}s) waiting for 8 exports under /tmp/snapshots/latest"

# LOAD-BEARING: capture (and COPY) the snapshot dir IMMEDIATELY. Late/retransmitted markers can
# hit sidecars that already finished their snapshot, re-triggering "ghost" checkpoints that both
# move the 'latest' symlink AND can overwrite tars in this very directory with post-cut state.
RUN_DIR=$(mktemp -d /tmp/wq_snapshot_run.XXXXXX)
cp -p "$SNAP_DIR"/*.tar.zst "$RUN_DIR"/ || die "failed to copy snapshot images out of $SNAP_DIR"
echo "[*] Snapshot images captured: $SNAP_DIR  ->  $RUN_DIR"

# Catch-window check (diagnostic). Markers fan out only AFTER the initiator's blocking agent
# call returns, i.e. after BOTH client-pair CRIU exports finished — approximated by the
# (cp -p preserved) mtime of sidecar-d's export. If trigger->fan-out took >= DELAY_MS, JOBs
# $JOB_A,$JOB_B reached the LIVE workers before their cut, landed inside the worker images, and
# leg (b) will "pass" for the wrong reason: report that as a blown catch window so the verdict
# is diagnosable instead of a bare EXPERIMENT: FAIL.
CATCH=OK
D_PAIR_TS=$(stat -c %Y "$RUN_DIR/sidecar-d.tar.zst")
CATCH_LAT=$(( D_PAIR_TS - TRIGGER_TS ))
if [ $(( CATCH_LAT * 1000 )) -ge "$DELAY_MS" ]; then
    CATCH=BLOWN
    echo "[!] WARNING: catch window blown: trigger->marker fan-out ~${CATCH_LAT}s >= DELAY_MS=${DELAY_MS}ms"
    echo "[!]          (client-pair checkpoint too slow). Re-run with e.g. DELAY_MS=$(( DELAY_MS * 2 ))."
else
    echo "[*] Catch window ok: trigger->marker fan-out ~${CATCH_LAT}s (< DELAY_MS=${DELAY_MS}ms)."
fi

# ---------------------------------------------------------------- phase 5: live continuation
phase "PHASE 5: LIVE — remove netem, sanity-verify the live system completes all $N_JOBS jobs"
# After each agent call returned, the live system kept going (--leave-running): markers closed
# the channels, recorded in-flight JOBs were replayed into the LIVE apps. This proves the cut
# itself broke nothing; both restore legs below start from the same images regardless.

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
    phase "PHASE 6: RESTORE (a) — kill all 8, restore apps THEN sidecars from the cut images"
    # Restored sidecars resume inside their broken agent HTTP call, hit the except branch, and
    # re-execute the marker broadcast with cut-time seq state: the coordinator re-sends marker
    # seq n+1 FIFO behind retransmitted JOB seq n; each worker records the JOB, closes the
    # channel, and the recorded JOB is spoof-delivered into the restored worker app.
    kill_all
    restore_apps        # apps FIRST (see restore_apps comment)
    restore_sidecars
    settle
    if verify_loopback "$N_JOBS"; then RES_A=PASS; else RES_A=FAIL; fi
    echo "[*] restore (a) verify: $RES_A (expected PASS)"
fi

# ---------------------------------------------------------------- phase 7: restore leg (b)
phase "PHASE 7: RESTORE (b) CONTROL — same app images, FRESH sidecars (channel state discarded)"
# This is what a naive CRIU-only checkpoint yields. JOBs $JOB_A,$JOB_B exist in NO app image
# (the coordinator forwarded-and-forgot; the workers never received them) and the recorded
# channel state died with the old sidecars. The coordinator has no dispatch log to recover from.

kill_all
restore_apps            # ONLY the 4 app containers, from the SAME images
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
echo "  catch window                 $CATCH       OK (trigger->fan-out ${CATCH_LAT}s, DELAY_MS=${DELAY_MS})"
echo "  live continuation            $LIVE     PASS"
echo "  restore (a) proxy-consistent $RES_A     PASS"
echo "  restore (b) CRIU-only        $RES_B     FAIL missing=$JOB_A,$JOB_B ${B_DETAIL:+ (got: $B_DETAIL)}"
echo
echo "  snapshot images: $RUN_DIR"

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
        echo "  EXPERIMENT: PASS (checkpoint correctness demonstrably depends on the proxy)"
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
