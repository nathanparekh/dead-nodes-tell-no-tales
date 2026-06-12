#!/bin/bash
# mesh_ctl.sh
#
# Drive counter.py over the mesh from ONE node, via a long-lived control
# container ("mesh-ctl") attached to the VXLAN overlay at 10.24.24.200, plus
# its own sidecar ("sidecar-ctl"). This is the operator's hand on the mesh:
# warm peer pairs, transfer, reset, and sum across nodes A/B/C.
#
# Usage: ./mesh_ctl.sh bootstrap [per_node]   |   ./mesh_ctl.sh <counter.py args...>
#   ./mesh_ctl.sh bootstrap          # reset all to 10, warm every pair, verify total 30
#   ./mesh_ctl.sh bootstrap 100      # same, but 100 per node (total 300)
#   ./mesh_ctl.sh reset 10.24.24.10 5000 100
#   ./mesh_ctl.sh transfer 10.24.24.10 5000 10.24.24.11 5000 5
#   ./mesh_ctl.sh sum 10.24.24.10 5000 10.24.24.11 5000 10.24.24.12 5000 300 5000 3
#
# 6-node snapshot test (counter-a..f at 10.24.24.10..15):
#   ./mesh_ctl.sh bootstrap6 [per_node]      # reset .10..15, warm the ring, verify total 6*per_node
#   ./mesh_ctl.sh sum6 [expected]            # verify total across all six (default 60)
#   ./mesh_ctl.sh load <seconds> [delay_ms] [amount]   # continuous ring transfers (backgroundable)
#
# Honors env MESH_NET (default "vlan"); the operator pre-creates that overlay.

set -u

MESH_NET="${MESH_NET:-vlan}"

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 bootstrap [per_node]   |   $0 <counter.py args...>"
    echo "Example: $0 bootstrap"
    echo "         $0 transfer 10.24.24.10 5000 10.24.24.11 5000 5"
    exit 1
fi

# 1. Ensure the images exist. The control container runs counter.py from the
#    test-runner image (WORKDIR /test); the sidecar provides TPROXY tunneling.
if ! sudo podman image exists test-runner; then
    echo "[*] Building test-runner image..."
    sudo podman build --network=host -t test-runner -f Containerfile.test .
fi
if ! sudo podman image exists sidecar; then
    echo "[*] Building sidecar image..."
    sudo podman build --network=host -t sidecar -f Containerfile.rudp .
fi

# 2. Ensure the control container + its sidecar are up on the overlay.
#    The control container holds a fixed mesh IP (10.24.24.200) so peers have a
#    stable address to reply to. It needs the sidecar sharing its netns because
#    the app nodes tunnel their replies back to 10.24.24.200 over RUDP/TPROXY;
#    without the sidecar those replies would never be de-tunnelled and reads
#    like `sum`/`state` would hang.
if ! sudo podman container exists mesh-ctl || \
   [ "$(sudo podman inspect -f '{{.State.Running}}' mesh-ctl 2>/dev/null)" != "true" ]; then
    echo "[*] Starting control container mesh-ctl on $MESH_NET (10.24.24.200)"
    sudo podman run -d --replace \
      --name mesh-ctl \
      --network "${MESH_NET}:ip=10.24.24.200" \
      --entrypoint sleep \
      test-runner infinity

    echo "[*] Attaching sidecar-ctl (shares mesh-ctl netns)"
    sudo podman run -d --replace \
      --name sidecar-ctl \
      --network container:mesh-ctl \
      --cap-add NET_ADMIN \
      --sysctl net.ipv4.ip_nonlocal_bind=1 \
      -e MESH_SUBNET=10.24.24.0/24 \
      sidecar

    sleep 1  # give the sidecar a moment to install its TPROXY rules
fi

# 3. Run the command (counter.py lives at /test). `bootstrap` is a convenience
#    verb for the whole "drive the mesh" step: reset all three nodes, warm every
#    directed pair (a ring of +1 transfers that nets to zero -- total unchanged,
#    every sidecar learns every peer), then verify the conserved total. Any other
#    args are passed straight through to counter.py.
cexec() { sudo podman exec mesh-ctl ./counter.py "$@"; }

if [ "$1" = "bootstrap" ]; then
    PER_NODE="${2:-10}"
    EXPECTED=$(( PER_NODE * 3 ))
    echo "[*] bootstrap: reset all -> $PER_NODE, warm A->B->C->A, verify total=$EXPECTED"
    cexec reset 10.24.24.10 5000 "$PER_NODE"                            && \
    cexec reset 10.24.24.11 5000 "$PER_NODE"                            && \
    cexec reset 10.24.24.12 5000 "$PER_NODE"                            && \
    cexec transfer 10.24.24.10 5000 10.24.24.11 5000 1                  && \
    cexec transfer 10.24.24.11 5000 10.24.24.12 5000 1                  && \
    cexec transfer 10.24.24.12 5000 10.24.24.10 5000 1                  && \
    cexec sum 10.24.24.10 5000 10.24.24.11 5000 10.24.24.12 5000 "$EXPECTED" 5000 3
    exit $?
fi

# The six member IPs for the 6-node snapshot test (counter-a .. counter-f), all
# on app port 5000. Used by bootstrap6/sum6/load below.
MEMBERS=(10.24.24.10 10.24.24.11 10.24.24.12 10.24.24.13 10.24.24.14 10.24.24.15)

if [ "$1" = "bootstrap6" ]; then
    PER_NODE="${2:-10}"
    EXPECTED=$(( PER_NODE * 6 ))
    echo "[*] bootstrap6: reset .10..15 -> $PER_NODE, warm the ring, verify total=$EXPECTED"
    # Reset every member to per_node.
    for ip in "${MEMBERS[@]}"; do
        cexec reset "$ip" 5000 "$PER_NODE" || exit $?
    done
    # Warm the ring .10->.11->...->.15->.10 with +1 transfers so every sidecar
    # learns live peer state; the ring nets to zero so the total is unchanged.
    n=${#MEMBERS[@]}
    for i in $(seq 0 $(( n - 1 ))); do
        from="${MEMBERS[$i]}"
        to="${MEMBERS[$(( (i + 1) % n ))]}"
        cexec transfer "$from" 5000 "$to" 5000 1 || exit $?
    done
    # Verify the conserved total across all six.
    cexec sumn "$EXPECTED" 5000 3 \
        10.24.24.10 5000 10.24.24.11 5000 10.24.24.12 5000 \
        10.24.24.13 5000 10.24.24.14 5000 10.24.24.15 5000
    exit $?
fi

if [ "$1" = "sum6" ]; then
    EXPECTED="${2:-60}"
    echo "[*] sum6: verify total across .10..15 == $EXPECTED"
    cexec sumn "$EXPECTED" 5000 3 \
        10.24.24.10 5000 10.24.24.11 5000 10.24.24.12 5000 \
        10.24.24.13 5000 10.24.24.14 5000 10.24.24.15 5000
    exit $?
fi

if [ "$1" = "load" ]; then
    # load <seconds> [delay_ms] [amount]: continuously dispatch transfers around
    # the six-member ring for <seconds> wall-clock. Meant to be backgrounded by
    # the test (runs before/during/after the snapshot). Each transfer conserves
    # money, so the live total stays constant throughout.
    SECONDS_TO_RUN="${2:-}"
    DELAY_MS="${3:-100}"
    AMOUNT="${4:-1}"
    if [ -z "$SECONDS_TO_RUN" ]; then
        echo "Usage: $0 load <seconds> [delay_ms] [amount]"
        exit 1
    fi
    n=${#MEMBERS[@]}
    end=$(( $(date +%s) + SECONDS_TO_RUN ))
    # Fractional sleep interval (delay_ms milliseconds) as decimal seconds.
    interval="$(awk "BEGIN{printf \"%.3f\", $DELAY_MS/1000}")"
    echo "[load] dispatching ring transfers of $AMOUNT for ${SECONDS_TO_RUN}s (delay ${DELAY_MS}ms)"
    i=0
    while [ "$(date +%s)" -lt "$end" ]; do
        from="${MEMBERS[$(( i % n ))]}"
        to="${MEMBERS[$(( (i + 1) % n ))]}"
        txid="ld$i"
        # Tolerate nonzero: the control reply may time out under load, but the
        # debit+credit still happen on the apps. Never abort the loop.
        cexec transfer "$from" 5000 "$to" 5000 "$AMOUNT" "$txid" >/dev/null 2>&1 || true
        i=$(( i + 1 ))
        if [ $(( i % 25 )) -eq 0 ]; then
            echo "[load] dispatched $i transfers"
        fi
        sleep "$interval"
    done
    echo "[load] done after $i transfers"
    exit 0
fi

cexec "$@"
