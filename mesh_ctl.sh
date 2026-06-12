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

cexec "$@"
