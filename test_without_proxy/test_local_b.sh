#!/bin/bash

# without migration, just pausing container and restoring it from checkpoint

set -euo pipefail

PORT=5000
EXPECTED=30
TIMEOUT_MS=5000
STABLE_POLLS=10
B_CONTAINER=counter-b
B_CHECKPOINT=/tmp/counter-b-checkpoint.tar.zst
B_RESTORE_NAME=counter-b

echo "Reset all counters to 10."
/usr/local/bin/counter reset "$A_HOST" "$PORT" 10
/usr/local/bin/counter reset "$B_HOST" "$PORT" 10
/usr/local/bin/counter reset "$C_HOST" "$PORT" 10

echo "Initial state:"
/usr/local/bin/counter sum "$A_HOST" "$PORT" "$B_HOST" "$PORT" "$C_HOST" "$PORT" \
  "$EXPECTED" "$TIMEOUT_MS" "$STABLE_POLLS" 

echo "Checkpointing local B."
rm -f "$B_CHECKPOINT"
podman ps
podman container checkpoint "$B_CONTAINER" --export "$B_CHECKPOINT"
podman rm "$B_CONTAINER" >/dev/null

echo "Sending A -> B while local B is absent. A debits; the UDP credit should disappear."
/usr/local/bin/counter transfer "$A_HOST" "$PORT" "$B_HOST" "$PORT" 7

echo "Restoring local B from the checkpoint tar."
podman container restore --import "$B_CHECKPOINT" --tcp-established

sleep 1

/usr/local/bin/counter sum "$A_HOST" "$PORT" "$B_HOST" "$PORT" "$C_HOST" "$PORT" \
  "$EXPECTED" "$TIMEOUT_MS" "$STABLE_POLLS"

