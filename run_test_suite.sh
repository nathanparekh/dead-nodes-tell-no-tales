#!/bin/bash
# run_test_suite.sh
set -euo pipefail

# 1. Build the test suite runner container
echo "Building test-runner..."
sudo podman build --network=host -t test-runner -f Containerfile.test .

# 2. Ensure the HOST Podman system service is running as absolute root
if ! sudo pgrep -f "podman system service" > /dev/null; then
    echo "Starting root host Podman system service daemon..."
    # Launching explicitly via sudo to handle CRIU root requirements
    sudo podman system service --time=0 unix:///run/podman/podman.sock &
    sleep 2
fi

# 3. Run the test runner, forcing standard podman to route through the host socket
echo "Executing test runner environment..."
sudo podman run --rm -it \
  --network vlan \
  --privileged \
  -v /run/podman/podman.sock:/run/podman/podman.sock:rw \
  -v /tmp:/tmp:rw \
  -e CONTAINER_HOST=unix:///run/podman/podman.sock \
  -e CONTAINER_CONNECTION=host-root-daemon \
  --name test-container \
  test-runner


echo "Attaching Sidecar Proxy to test container"
sudo podman run -d --replace \
  --name "sidecar-test" \
  --network "container:test-container" \
  --cap-add NET_ADMIN \
  -e MESH_SUBNET="$MESH_SUBNET" \
  sidecar