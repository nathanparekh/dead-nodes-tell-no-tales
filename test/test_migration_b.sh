#!/usr/bin/env bash
PORT=5000
EXPECTED=30
TIMEOUT_MS=5000
STABLE_POLLS=10
B_CONTAINER=counter-b
B_CHECKPOINT=/tmp/counter-b-checkpoint.tar.zst
B_RESTORE_NAME=counter-b

# run on instance A or C, w B_SSH so that we can restore on B
echo "Initial state:"
./counter sum "$A_HOST" "$PORT" "$B_HOST" "$PORT" "$C_HOST" "$PORT" \
  "$EXPECTED" "$TIMEOUT_MS" "$STABLE_POLLS"

echo "Checkpointing B on $B_SSH."
"ssh" "$B_SSH" \
  "rm -f '$B_CHECKPOINT'; podman container checkpoint '$B_CONTAINER' --export '$B_CHECKPOINT'; podman rm '$B_CONTAINER' >/dev/null"

echo "Sending A -> B while B is absent. A debits locally; the UDP credit should disappear."
./counter transfer "$A_HOST" "$PORT" "$B_HOST" "$PORT" 7 tx-vxlan-criu-loss-1

# scp the file over to this instance
echo "Copying checkpoint tar from $B_SSH to this node."
"scp" "$B_SSH:$B_CHECKPOINT" "$B_CHECKPOINT"

echo "Restoring B from the checkpoint tar."
  "podman container restore --import '$B_CHECKPOINT' --name '$B_RESTORE_NAME'"

sleep 1

echo "Final state over VXLAN. This is expected to FAIL before the proxy solution exists."
./counter sum "$A_HOST" "$PORT" "$B_HOST" "$PORT" "$C_HOST" "$PORT" \
  "$EXPECTED" "$TIMEOUT_MS" "$STABLE_POLLS"
