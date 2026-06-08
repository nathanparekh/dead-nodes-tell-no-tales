#!/bin/bash
# test_local_b.sh
set -euo pipefail

PORT=9000
EXPECTED=30
TIMEOUT_MS=5000
STABLE_POLLS=10
B_CONTAINER=counter-b

echo "Reset all counters to 10."
# Note: Ensure nodes are freshly deployed or sidecars accept direct local loopback tools
/usr/local/bin/counter reset "$A_HOST" "$PORT" 10
/usr/local/bin/counter reset "$B_HOST" "$PORT" 10
/usr/local/bin/counter reset "$C_HOST" "$PORT" 10

echo "Initial state:"
/usr/local/bin/counter sum "$A_HOST" "$PORT" "$B_HOST" "$PORT" "$C_HOST" "$PORT" \
  "$EXPECTED" "$TIMEOUT_MS" "$STABLE_POLLS" 

echo "Checkpointing local B and its sidecar safely..."
# Crucial: Use --tcp-established to freeze network interface sockets properly
sudo podman container checkpoint counter-b --tcp-established --export /tmp/counter-b.tar.zst
sudo podman container checkpoint sidecar-b --tcp-established --export /tmp/sidecar-b.tar.zst

sudo podman rm -f sidecar-b counter-b >/dev/null

echo "Sending A -> B while local B is absent."
echo "Sidecar A will intercept this, queue it, and persistently retry behind the scenes."
/usr/local/bin/counter transfer "$A_HOST" "$PORT" "$B_HOST" "$PORT" 7

echo "Restoring local B components onto their macvlan network space."
# Crucial: Add --tcp-established on restore so they don't lose network bindings
sudo podman container restore --tcp-established --import /tmp/counter-b.tar.zst --name counter-b
sudo podman container restore --tcp-established --import /tmp/sidecar-b.tar.zst --name sidecar-b

echo "Waiting for proxy to flush queued buffers..."
sleep 1.5

echo "Final state check (RUDP ensures no credits vanish; total should stay 30):"
/usr/local/bin/counter sum "$A_HOST" "$PORT" "$B_HOST" "$PORT" "$C_HOST" "$PORT" \
  "$EXPECTED" "$TIMEOUT_MS" "$STABLE_POLLS"