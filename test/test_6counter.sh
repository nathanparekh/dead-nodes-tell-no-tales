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

# Poll the total until it settles at $1 (async credits need a moment to land).
verify_total() {
    local want=$1 t
    for _ in $(seq 1 20); do
        t=$(total6)
        echo "    total=$t (want $want)"
        [ "$t" = "$want" ] && return 0
        sleep 0.5
    done
    return 1
}

# Continuous +1 ring of transfers. Each full lap nets to zero, so the global
# total is conserved; runs until killed.
load_loop() {
    while :; do
        for ((i = 0; i < N; i++)); do
            ctl transfer "${IPS[i]}" "$PORT" "${IPS[(i + 1) % N]}" "$PORT" 1 >/dev/null 2>&1
            sleep 0.2
        done
    done
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

# 2. Start the continuous load and make sure it is killed on any exit.
load_loop & LOOP_PID=$!
trap 'kill "$LOOP_PID" 2>/dev/null' EXIT
echo "[*] Continuous transfers running (pid $LOOP_PID); letting traffic flow BEFORE the snapshot..."
sleep 3

# 3. Snapshot mid-flight.
echo "[*] Triggering global snapshot '$SNAP_ID' from node $INIT_NODE while load continues..."
./trigger_snapshot.sh "$INIT_NODE" "$SNAP_ID"

# 4. Keep the load flowing after the cut, then stop it.
echo "[*] Snapshot triggered; keeping load running AFTER the cut..."
sleep 3
kill "$LOOP_PID" 2>/dev/null; wait "$LOOP_PID" 2>/dev/null; trap - EXIT
echo "[*] Stopped continuous load."

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
echo "To exercise recovery, run ./run_restore.sh $SNAP_ID <suffix> on each node."
