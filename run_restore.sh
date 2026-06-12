#!/bin/bash
# run_restore.sh <snapshot_id> [nodes...]
#
# Drives a whole-system restore from a previously captured snapshot via the
# host-side breakout receiver over HTTP. Per node we stop the old sidecar +
# app, restore the app from its CRIU image, then start a FRESH restore-mode
# sidecar that loads this node's artifact (RESTORE_SNAPSHOT_ID) and replays
# the recorded channel into the local app before resuming live traffic.
# Calls are synchronous: curl returns once the receiver's podman command has
# finished, and a failed call aborts the run (except the best-effort stops in
# step 1, where a node may already be gone).

set -u

BREAKOUT_URL="${BREAKOUT_URL:-http://10.99.0.1:8989}"

SNAPSHOT_ID="${1:-}"
if [ -z "$SNAPSHOT_ID" ]; then
    echo "usage: $0 <snapshot_id> [nodes...]   (default nodes: a b c)" >&2
    exit 1
fi
shift

NODES=("$@")
if [ "${#NODES[@]}" -eq 0 ]; then
    NODES=(a b c)
fi

breakout() { # usage: breakout <endpoint> <json-body>
    # --max-time bounds each call: a restore may take up to the receiver's
    # 120s command timeout, so allow a little more. A dropped/firewalled
    # receiver then fails in seconds, not minutes of SYN retransmits.
    if ! curl -fsS --max-time 150 -X POST -H "Content-Type: application/json" \
            -d "$2" "$BREAKOUT_URL/$1"; then
        echo "ERROR: breakout $1 $2 failed; aborting" >&2
        exit 1
    fi
    echo
}

breakout_ok() { # usage: breakout_ok <endpoint> <json-body>
    # Best-effort variant: log and continue on failure (the target may already
    # be gone). Used only for the step-1 stops.
    if ! curl -fsS --max-time 150 -X POST -H "Content-Type: application/json" \
            -d "$2" "$BREAKOUT_URL/$1"; then
        echo "WARN: breakout $1 $2 failed; continuing (already gone?)" >&2
        return 0
    fi
    echo
}

# Ensure THIS node's breakout receiver is RESPONSIVE (restore drives the LOCAL
# receiver). It is single-threaded, so a slow/hung podman op (checkpoint/restore)
# blocks it and /health can time out even though it is alive and holding the port
# -- naively starting a second one then dies with EADDRINUSE. So: retry a few
# times (a busy receiver usually frees up); only if it stays unresponsive treat it
# as wedged -- kill the stale instance (freeing the port) and start fresh.
# Run from the repo root so proxy/breakout_receiver.py resolves.
start_receiver() {
    sudo setsid python3 proxy/breakout_receiver.py --host 10.99.0.1 --port 8989 \
        --mesh-subnet 10.24.24.0/24 </dev/null >/tmp/breakout-receiver.log 2>&1 &
    sleep 2
}
for _attempt in 1 2 3 4 5; do
    if curl -fsS --max-time 5 "$BREAKOUT_URL/health" >/dev/null 2>&1; then
        break
    fi
    if [ "$_attempt" -lt 5 ]; then
        echo "[*] receiver at $BREAKOUT_URL not responding; waiting (may be busy)..."
        sleep 3
        continue
    fi
    echo "[*] receiver wedged/down; killing any stale instance and restarting..."
    sudo pkill -f 'breakout_receiver.py --host' 2>/dev/null || true
    sleep 1
    start_receiver
    if ! curl -fsS --max-time 5 "$BREAKOUT_URL/health" >/dev/null 2>&1; then
        echo "ERROR: breakout receiver still unreachable at $BREAKOUT_URL after restart;" >&2
        echo "       check /tmp/breakout-receiver.log; run from the repo root." >&2
        exit 1
    fi
done

echo "Restoring snapshot $SNAPSHOT_ID across nodes: ${NODES[*]}"

# Step 1: stop the old components. Sidecar before app -- the sidecar shares the
# app's network namespace, so the app must outlive it. Tolerate a node that is
# already gone.
echo "Stopping old sidecars and apps."
for node in "${NODES[@]}"; do
    breakout_ok stop "{\"container_id\": \"sidecar-$node\"}"
    breakout_ok stop "{\"container_id\": \"counter-$node\"}"
done

# Step 2: restore each app from its CRIU image. HOST paths -- this caller never
# sees the tarballs.
echo "Restoring apps from their CRIU images."
for node in "${NODES[@]}"; do
    breakout restore "{\"target_path\": \"/tmp/snapshot-$SNAPSHOT_ID-counter-$node.tar.zst\"}"
done

# Step 3: let each restored app finish coming up and start listening before its
# fresh sidecar replays the recorded channel into it.
echo "Waiting for restored apps to start listening."
sleep 2

# Step 4: start a fresh restore-mode sidecar per node. RESTORE_SNAPSHOT_ID makes
# each sidecar load its node's artifact, set per-peer send_seq/recv_seq, replay
# the channel once in seq order, then resume.
echo "Starting fresh restore-mode sidecars."
for node in "${NODES[@]}"; do
    breakout run_sidecar "{\"node\": \"$node\", \"snapshot_id\": \"$SNAPSHOT_ID\"}"
done

echo "Restore complete. Verify with: sum of the node counters should equal 30."
