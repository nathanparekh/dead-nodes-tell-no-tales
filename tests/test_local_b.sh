#!/bin/bash

# without migration, just pausing container

set -euo pipefail

PORT=9000
EXPECTED=30
TIMEOUT_MS=5000
STABLE_POLLS=10
B_CONTAINER=counter-b
B_CHECKPOINT=/tmp/counter-b-checkpoint.tar.zst
B_RESTORE_NAME=counter-b

echo "Initial state:"
./counter sum "$A_HOST" "$PORT" "$B_HOST" "$PORT" "$C_HOST" "$PORT" \
  "$EXPECTED" "$TIMEOUT_MS" "$STABLE_POLLS"

echo "Checkpointing local B."
rm -f "$B_CHECKPOINT"
sudo podman container checkpoint "$B_CONTAINER" --export "$B_CHECKPOINT"
sudo podman rm "$B_CONTAINER" >/dev/null

echo "Sending A -> B while local B is absent. A debits; the UDP credit should disappear."
./counter transfer "$A_HOST" "$PORT" "$B_HOST" "$PORT" 7

echo "Restoring local B from the checkpoint tar."
sudo podman container restore --import "$B_CHECKPOINT" --name "$B_RESTORE_NAME"

sleep 1

./counter sum "$A_HOST" "$PORT" "$B_HOST" "$PORT" "$C_HOST" "$PORT" \
  "$EXPECTED" "$TIMEOUT_MS" "$STABLE_POLLS"
