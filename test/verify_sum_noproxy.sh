#!/bin/bash
# verify_sum_noproxy.sh [expected_total]  — read the 6 sidecar-less counters
# over the raw-UDP mesh and check whether the global total is conserved
# (default expected: 60).
#
# Counterexample twin of verify_sum.sh. Run from ONE node AFTER restore_criu.sh
# has run on each node. Unlike verify_sum.sh it polls until the total is STABLE
# (not until it matches), then reports CONSERVED or VIOLATED with the delta.
# For the plain-CRIU counterexample VIOLATED is the EXPECTED outcome — the exit
# code is still 1 (this is a conservation check), but that failure is the
# demonstration, to be contrasted with verify_sum.sh after run_restore.sh.
set -u

cd "$(dirname "$0")/.."

EXPECTED="${1:-60}"
PORT=5000
MESH_NET="${MESH_NET:-vlan}"
CTL=mesh-ctl-np
CTL_IP=10.24.24.201
IPS=(10.24.24.10 10.24.24.11 10.24.24.12 10.24.24.13 10.24.24.14 10.24.24.15)

ctl() { sudo podman exec "$CTL" ./counter.py "$@"; }

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

# Always RECREATE the control container. A restored counter comes back with a
# fresh MAC (podman ignores macvlan mac=), so an old control would keep sending
# to the stale MAC and the node would look MISSING. With no sidecars there is
# no netns to `ip neigh flush` through; a fresh control starts with an empty
# ARP cache, and its ARP requests re-announce its own MAC to every counter —
# healing both directions.
echo "[*] Bringing up sidecar-less control container $CTL @ $CTL_IP..."
if ! sudo podman image exists test-runner; then
    sudo podman build --network=host -t test-runner -f Containerfile.test .
fi
sudo podman run -d --replace --name "$CTL" \
    --network "${MESH_NET}:ip=$CTL_IP" \
    --entrypoint sleep test-runner infinity >/dev/null

echo "[*] Polling the 6-counter total until it settles (expected $EXPECTED)..."
last="" stable=0
for _ in $(seq 1 40); do
    t=$(total6)
    echo "    total=$t (expected $EXPECTED)"
    if [ "$t" = "$last" ] && [[ "$t" =~ ^-?[0-9]+$ ]]; then
        stable=$((stable + 1))
        [ "$stable" -ge 3 ] && break
    else
        stable=0
    fi
    last="$t"
    sleep 1
done

if [ "$stable" -lt 3 ]; then
    echo "FAIL: total never settled (last reading: $last)." >&2
    exit 1
fi

if [ "$last" = "$EXPECTED" ]; then
    echo "CONSERVED: total $last == $EXPECTED."
    exit 0
fi

echo "VIOLATED: total $last != $EXPECTED (delta $((last - EXPECTED)))."
echo "Plain per-container CRIU produced an inconsistent cut: in-flight credits"
echo "were in no image and post-dump work was rolled back unevenly. This is the"
echo "counterexample — compare with verify_sum.sh after the sidecar snapshot +"
echo "run_restore.sh, where the total survives."
exit 1
