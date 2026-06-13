#!/bin/bash
# verify_sum.sh [expected_total]  — open a control container and check that the 6
# counters sum to the expected total (default 60).
#
# Use it AFTER a per-node restore (run_restore.sh on each node) to confirm the
# global total was conserved across snapshot + restore. Unlike re-running
# test_6counter.sh, this does NOT reset anything — it reads the live post-restore
# values, so it actually verifies the restore rather than masking it.
#
# Runs from ONE node, no SSH: it brings up the control container (mesh-ctl @
# 10.24.24.200) via mesh_ctl.sh and queries all six over the mesh. counter.py is
# unchanged (its `sum` verb only spans 3 nodes, so we sum the six via `state`).
set -u

cd "$(dirname "$0")/.."

EXPECTED="${1:-60}"
PORT=5000
IPS=(10.24.24.10 10.24.24.11 10.24.24.12 10.24.24.13 10.24.24.14 10.24.24.15)

ctl() { sudo podman exec mesh-ctl ./counter.py "$@"; }

# Flush stale ARP in every local sidecar netns. A just-restored node comes back
# with a MAC that peers (including the control container) still have cached, so
# without this the control's reads can black-hole and a healthy node looks
# MISSING. Flushing sidecar-ctl re-resolves every peer on the next send; `ip
# neigh flush` needs NET_ADMIN (the sidecars have it and share their app netns)
# and `ip` ships in the image.
flush_neighbors() {
    local sc
    for sc in $(sudo podman ps --format '{{.Names}}' | grep -E '^sidecar-' || true); do
        sudo podman exec "$sc" ip neigh flush all 2>/dev/null && echo "    flushed ARP cache in $sc"
    done
}

# Sum the 6 counters via `state`. Echoes the total, or "MISSING:<ip>" + return 1.
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

echo "[*] Bringing up control container..."
./mesh_ctl.sh state "${IPS[0]}" "$PORT" >/dev/null 2>&1 || true   # spins up mesh-ctl + sidecar-ctl

echo "[*] Flushing stale ARP caches (a just-restored node re-resolves on next send)..."
flush_neighbors

echo "[*] Verifying the 6 counters sum to $EXPECTED (polling until it settles)..."
for _ in $(seq 1 30); do
    t=$(total6)
    echo "    total=$t (want $EXPECTED)"
    if [ "$t" = "$EXPECTED" ]; then
        echo "PASS: counters sum to $EXPECTED — total conserved across snapshot + restore."
        exit 0
    fi
    sleep 1
done

echo "FAIL: counters did not settle at $EXPECTED."
exit 1
