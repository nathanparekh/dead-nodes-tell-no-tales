#!/bin/bash
# test_local_b.sh

PORT=5000
EXPECTED=30
TIMEOUT_MS=5000
STABLE_POLLS=10
B_CONTAINER=counter-b

echo "Reset all counters to 10."
./counter.py reset "$A_HOST" "$PORT" 10
echo "a reset"
./counter.py reset "$B_HOST" "$PORT" 10
echo "b reset"
./counter.py reset "$C_HOST" "$PORT" 10
echo "c reset"

echo "Initial state:"
./counter.py sum "$A_HOST" "$PORT" "$B_HOST" "$PORT" "$C_HOST" "$PORT" \
  "$EXPECTED" "$TIMEOUT_MS" "$STABLE_POLLS" 

echo "Checkpointing local B and its sidecar safely..."
# Crucial: Use --tcp-established to freeze network interface sockets properly
podman container ps
podman container checkpoint counter-b --export /tmp/counter-b.tar.zst
if [ "$PROXY" = true ]; then
    podman container checkpoint sidecar-b --export /tmp/sidecar-b.tar.zst
fi

podman rm -f sidecar-b counter-b >/dev/null

echo "Sending A -> B while local B is absent."
echo "Sidecar A will intercept this, queue it, and persistently retry behind the scenes."
./counter.py transfer "$A_HOST" "$PORT" "$B_HOST" "$PORT" 7

echo "Restoring local B components onto their macvlan network space."
# Crucial: Add --tcp-established on restore so they don't lose network bindings
podman container restore --tcp-established --import /tmp/counter-b.tar.zst
if [ "$PROXY" = true ]; then
    podman container restore --tcp-established --import /tmp/sidecar-b.tar.zst
fi

echo "Waiting for proxy to flush queued buffers..."
sleep 1.5

echo "Final state check (RUDP ensures no credits vanish; total should stay 30):"
./counter.py sum "$A_HOST" "$PORT" "$B_HOST" "$PORT" "$C_HOST" "$PORT" \
  "$EXPECTED" "$TIMEOUT_MS" "$STABLE_POLLS"