#!/bin/bash
# run_test_suite.sh
set -euo pipefail

# 1. Build the test suite runner container
echo "Building udp-test-runner..."
sudo podman build -t udp-test-runner -f Containerfile.tests .

# 2. Ensure Podman system service is running on the host to accept remote connection
if ! pgrep -f "podman system service" > /dev/null; then
    echo "Starting host Podman system service daemon..."
    sudo podman system service --time=0 unix:///run/podman/podman.sock &
    sleep 1
fi

# 3. Run the specific test inside the macvlan network space
# We pass the Podman socket, the checkpoint shared directory, and target the network
echo "Executing test runner environment..."
sudo podman run --rm -it \
  --network vlan \
  -v /run/podman/podman.sock:/run/podman/podman.sock:rw \
  -v /tmp:/tmp:rw \
  -e CONTAINER_HOST=unix:///run/podman/podman.sock \
  udp-test-runner