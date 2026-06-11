#!/bin/bash
# run_test_suite.sh

BREAKOUT_NET=breakout
BREAKOUT_GW=10.99.0.1
BREAKOUT_PORT=8989
BREAKOUT_URL="http://$BREAKOUT_GW:$BREAKOUT_PORT"
# The sidecar auto-detects the mesh subnet from its routes; with the breakout
# network now also attached that becomes ambiguous, so pin it explicitly.
MESH_SUBNET="${MESH_SUBNET:-10.24.24.0/24}"

PROXY=true
if [ "$1" = "n" ]; then
    PROXY=false
fi

# 1. Build the test suite runner container
echo "Building test-runner..."
sudo podman build --network=host -t test-runner -f Containerfile.test .

# 2. Ensure the breakout bridge network exists. Fixed subnet/gateway so the
#    receiver has a deterministic internal address to bind.
if ! sudo podman network exists "$BREAKOUT_NET"; then
    echo "Creating breakout network ($BREAKOUT_GW)..."
    sudo podman network create --subnet 10.99.0.0/24 --gateway "$BREAKOUT_GW" "$BREAKOUT_NET"
fi

# 3. Ensure the breakout receiver is running on the host (replaces the old
#    podman system service + socket mount; root for CRIU requirements).
#    Probe the port rather than pgrep -- a substring match on the filename also
#    hits editors and sudo's own wrapper, wrongly suppressing startup.
if ! timeout 2 bash -c "exec 3<>/dev/tcp/$BREAKOUT_GW/$BREAKOUT_PORT" 2>/dev/null; then
    echo "Starting breakout receiver on $BREAKOUT_URL..."
    sudo python3 proxy/breakout_receiver.py --host "$BREAKOUT_GW" --port "$BREAKOUT_PORT" &
    sleep 1
fi

# 4. Run the test runner; podman operations go through the breakout receiver
echo "Executing test runner environment..."
sudo podman run -d --replace \
  --network vlan \
  --network "$BREAKOUT_NET" \
  -e BREAKOUT_URL="$BREAKOUT_URL" \
  -e PROXY="$PROXY" \
  --name test-container \
  test-runner

if [ "$PROXY" = true ]; then
    echo "Attaching Sidecar Proxy to test container"
    sudo podman run -d --replace \
    --name "sidecar-test" \
    --network "container:test-container" \
    --cap-add NET_ADMIN \
    -e MESH_SUBNET="$MESH_SUBNET" \
    sidecar
fi

sudo podman logs -f test-container
