#!/bin/bash
# test_6counter.sh [snapshot_id]  — 6-container Counter snapshot-under-load test.
#
# Topology: 6 counters (a..f, IPs .10..15), 3 per physical node across 2 nodes
# (a,b,c on A; d,e,f on B), deployed first with ./test/deploy6.sh on each node.
# This driver runs from ONE node (the
# snapshot initiator, node A) and drives everything through the control
# container (mesh-ctl @ 10.24.24.200) brought up by mesh_ctl.sh — NO SSH.
#
# What it does:
#   1. Reset all 6 counters to 10 (total 60) and warm the full ring so every
#      sidecar has learned every peer.
#   2. Start a CONTINUOUS ring of +1 transfers from the control container
#      (a->b->c->d->e->f->a, nets to zero so the total stays 60).
#   3. While that load is flowing, trigger a global Chandy-Lamport snapshot.
#   4. Keep the load flowing AFTER the cut, then stop it.
#   5. Verify the conserved total is still 60 — the cut was taken consistently
#      under live traffic.
#
# Restore is per-node and NOT driven here (run run_restore.sh on each node if
# you want to exercise it). counter.py is used as-is (its `sum` verb only spans
# 3 nodes, so we sum the 6 via `state` here).
set -u

cd "$(dirname "$0")/.."

INIT_NODE=a                 # initiator suffix — this node must be physical A
SNAP_ID="${1:-snap6}"
PORT=5000
PER_NODE=10
IPS=(10.24.24.10 10.24.24.11 10.24.24.12 10.24.24.13 10.24.24.14 10.24.24.15)
N=${#IPS[@]}
TOTAL=$(( PER_NODE * N ))    # 60

# Load generator knobs. The controller is MULTITHREADED so many transfers are in
# flight at once -- otherwise node->node CREDITs are delivered+ACKed faster than
# the marker sweep, the channels are ~always empty, and the snapshot records no
# in-flight state (the whole point of a Chandy-Lamport cut). Tune via env.
#
# The load runs continuously across THREE phases -- before the snapshot, during
# the marker sweep, and (crucially) for POST_SNAP_SECS AFTER the cut has been
# confirmed finished -- so the test shows the system still processing operations
# once the snapshot completes. It is stopped deterministically via a sentinel
# file (the alpine control image has no pkill), with LOAD_MAX_SECS as a backstop.
LOAD_THREADS="${LOAD_THREADS:-8}"       # concurrent in-flight transfer streams
PRE_SNAP_SECS="${PRE_SNAP_SECS:-3}"     # load-only seconds before the snapshot fires
POST_SNAP_SECS="${POST_SNAP_SECS:-5}"   # KEEP operating this long AFTER the cut finishes
SNAP_WAIT_SECS="${SNAP_WAIT_SECS:-30}"  # max seconds to wait for the cut to finish
LOAD_MAX_SECS="${LOAD_MAX_SECS:-120}"   # hard cap so the blaster can never run forever
STOP_FILE="/tmp/stop_load_$SNAP_ID"     # touch (in mesh-ctl) to stop the load

# Run a counter.py verb inside the already-running control container.
ctl() { sudo podman exec mesh-ctl ./counter.py "$@"; }

# Sum the 6 counters via `state` (counter.py `sum` only does 3). Echoes the
# total, or "MISSING" and returns 1 if any node didn't answer.
total6() {
    local s=0 ip out v
    for ip in "${IPS[@]}"; do
        out=$(ctl state "$ip" "$PORT" 2>/dev/null)   # "STATE <name> counter=<v>"
        case "$out" in
            *counter=*) v=${out##*counter=}; v=${v%%[!0-9-]*} ;;
            *) echo "MISSING:$ip"; return 1 ;;
        esac
        [ -z "$v" ] && { echo "MISSING:$ip"; return 1; }
        s=$((s + v))
    done
    echo "$s"
}

# Poll the total until it settles at $1 (a heavy concurrent load leaves many
# credits in flight, so give them time to drain after the load stops).
verify_total() {
    local want=$1 t
    for _ in $(seq 1 40); do
        t=$(total6)
        echo "    total=$t (want $want)"
        [ "$t" = "$want" ] && return 0
        sleep 0.5
    done
    return 1
}

# Start the load generator: a MULTITHREADED controller running INSIDE mesh-ctl.
# Each thread fires counter.py's exact TRANSFER wire format around the ring as
# fast as it can, so node->node CREDIT messages are genuinely traveling on the
# channels while the snapshot marker sweep runs -- with the old one-at-a-time
# loop the channels were ~always empty and the cut recorded nothing. Sends are
# fire-and-forget (replies ignored); counter.py is unmodified. Every TRANSFER
# debits one node and credits the next, so the global total stays conserved
# regardless of where the run is cut off. It runs until the sentinel file appears
# (driver-controlled, so the load can span before/during/after the cut) or the
# LOAD_MAX_SECS backstop trips -- so on the happy path there is nothing to reap.
start_load() {
    sudo podman exec mesh-ctl rm -f "$STOP_FILE" 2>/dev/null || true
    sudo podman exec -i mesh-ctl python3 - \
        "$LOAD_MAX_SECS" "$LOAD_THREADS" "$STOP_FILE" "${IPS[@]}" <<'PY' >/dev/null 2>&1 &
import socket, sys, threading, time, random, os
cap = float(sys.argv[1]); nthreads = int(sys.argv[2]); stop = sys.argv[3]; members = sys.argv[4:]
PORT = 5000
deadline = time.time() + cap
def worker():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    n = len(members)
    while time.time() < deadline and not os.path.exists(stop):
        i = random.randrange(n)
        frm, to = members[i], members[(i + 1) % n]
        try:
            s.sendto(f"TRANSFER tx123 {to} {PORT} 1".encode(), (frm, PORT))
        except OSError:
            pass
        time.sleep(0.01)
ts = [threading.Thread(target=worker) for _ in range(nthreads)]
for t in ts: t.start()
for t in ts: t.join()
PY
    LOAD_PID=$!
}

# Stop the load: drop the sentinel (the blaster's threads see it and exit), then
# reap the backgrounded podman exec. Idempotent -- safe to call from the trap.
stop_load() {
    sudo podman exec mesh-ctl touch "$STOP_FILE" 2>/dev/null || true
    [ -n "${LOAD_PID:-}" ] && wait "$LOAD_PID" 2>/dev/null
}

# Wait until the global cut has actually finished, with the load still running.
# The initiator (counter-$INIT_NODE) is the last to finalize -- it waits for all
# its markers to return -- so its artifact appearing on THIS node's local /tmp is
# our signal that the cut is done. (Per-node store; observable locally, no SSH.)
wait_snapshot() {
    local art="/tmp/snapshot-$SNAP_ID-counter-$INIT_NODE.json" i
    for i in $(seq 1 "$SNAP_WAIT_SECS"); do
        [ -f "$art" ] && { echo "    cut recorded: $art"; return 0; }
        sleep 1
    done
    echo "    WARN: cut artifact $art not seen after ${SNAP_WAIT_SECS}s; continuing anyway" >&2
    return 1
}

# Flush the neighbor (ARP) cache of every sidecar netns we can reach on THIS
# host. A node restored by an earlier run (e.g. counter-b/.11 via test_local_b.sh)
# comes back with a MAC that peers still have cached, so traffic to it
# black-holes until the entry is re-resolved. Flushing forces a fresh ARP on the
# next send. `ip neigh flush` needs NET_ADMIN, which the sidecars have (and they
# share their app's netns), so we flush via the sidecars; `ip` ships in the image
# (iproute2) whereas `ping` does not. Only local containers are reachable (no
# SSH) -- that is enough here because every sender that targets a counter in this
# test (the control container and counter-a..c) lives on this node.
flush_neighbors() {
    local sc
    for sc in $(sudo podman ps --format '{{.Names}}' | grep -E '^sidecar-' || true); do
        sudo podman exec "$sc" ip neigh flush all 2>/dev/null && echo "    flushed ARP cache in $sc"
    done
}

# 1. Bring up the control container (mesh_ctl.sh starts mesh-ctl + sidecar-ctl on
#    first use), flush stale ARP, then reset every node to 10.
echo "[*] Bringing up control container..."
./mesh_ctl.sh state "${IPS[0]}" "$PORT" >/dev/null 2>&1 || true   # spins up mesh-ctl + sidecar-ctl

echo "[*] Flushing stale ARP caches (heals a node restored with a changed MAC)..."
flush_neighbors

echo "[*] Resetting all 6 nodes to $PER_NODE..."
for ip in "${IPS[@]}"; do ctl reset "$ip" "$PORT" "$PER_NODE" >/dev/null; done

# Warm the full ring so every sidecar has learned every peer (and to create real
# in-flight/credit state for the cut to capture).
echo "[*] Warming the ring a->b->c->d->e->f->a..."
for ((i = 0; i < N; i++)); do
    ctl transfer "${IPS[i]}" "$PORT" "${IPS[(i + 1) % N]}" "$PORT" 1 >/dev/null
done

echo "[*] Pre-load check: total should settle at $TOTAL"
verify_total "$TOTAL" || { echo "FAIL: counters did not reach $TOTAL before load"; exit 1; }

# 2. Start the multithreaded load. The trap stops it on any early exit.
start_load
trap stop_load EXIT
echo "[*] Load generator running ($LOAD_THREADS threads, pid $LOAD_PID);"
echo "    letting traffic flow BEFORE the snapshot..."
sleep "$PRE_SNAP_SECS"

# 3. Snapshot WHILE the load is saturating the channels.
echo "[*] Triggering global snapshot '$SNAP_ID' from node $INIT_NODE while load continues..."
echo "    (watch a sidecar's logs for 'Caching in-flight message seq ...' -- that IS"
echo "     recorded channel state, and it only appears because the channels are busy.)"
./trigger_snapshot.sh "$INIT_NODE" "$SNAP_ID"

# 4. Keep operating ACROSS the cut: wait (load still running) for the cut to
#    finish, then deliberately keep the load going for POST_SNAP_SECS more so the
#    system is shown still processing operations AFTER the snapshot completes.
echo "[*] Snapshot triggered; waiting for the cut to finish (load still running)..."
wait_snapshot || true
echo "[*] Cut finished; KEEPING operations running for ${POST_SNAP_SECS}s after the snapshot..."
sleep "$POST_SNAP_SECS"

echo "[*] Stopping load..."
stop_load; trap - EXIT
echo "[*] Load stopped; letting in-flight credits drain..."
sleep 1

# 5. Verify conservation once traffic has drained.
echo "[*] Post-load check: total must return to $TOTAL"
if verify_total "$TOTAL"; then
    echo "PASS: total conserved at $TOTAL across a global snapshot taken under live load."
else
    echo "FAIL: total did not return to $TOTAL after the snapshot."
    exit 1
fi

echo
echo "Snapshot '$SNAP_ID' artifacts are PER NODE (on each node's local /tmp):"
echo "    /tmp/snapshot-$SNAP_ID-counter-<suffix>.json     (channel-state cut)"
echo "    /tmp/snapshot-$SNAP_ID-counter-<suffix>.tar.zst  (app CRIU image)"
echo "To exercise recovery: run ./run_restore.sh $SNAP_ID <this node's letters> on"
echo "each node (A: a b c, B: d e f), then ./test/verify_sum.sh to confirm the"
echo "restored counters still sum to $TOTAL."
