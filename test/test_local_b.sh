#!/bin/bash
# test_local_b.sh
#
# Podman lifecycle operations are delegated to the host-side breakout
# receiver over HTTP. Calls are synchronous: curl returns once the podman
# command has finished, and a failed call aborts the test. Export paths
# are HOST paths; this container never sees the tarballs.

PORT=5000
EXPECTED=30
TIMEOUT_MS=5000
STABLE_POLLS=10
BREAKOUT_URL="${BREAKOUT_URL:-http://10.99.0.1:8989}"

breakout() { # usage: breakout <endpoint> <json-body>
    # --max-time bounds each call: a checkpoint may take up to the receiver's
    # 120s command timeout, so allow a little more. A dropped/firewalled
    # receiver then fails in seconds, not minutes of SYN retransmits.
    if ! curl -fsS --max-time 150 -X POST -H "Content-Type: application/json" \
            -d "$2" "$BREAKOUT_URL/$1"; then
        echo "ERROR: breakout $1 $2 failed; aborting" >&2
        exit 1
    fi
    echo
}

if ! curl -fsS --max-time 5 "$BREAKOUT_URL/health" >/dev/null; then
    echo "ERROR: breakout receiver unreachable at $BREAKOUT_URL" >&2
    exit 1
fi

echo "Reset all counters to 10."
./counter.py reset "$A_HOST" "$PORT" 10
./counter.py reset "$B_HOST" "$PORT" 10
./counter.py reset "$C_HOST" "$PORT" 10

echo "Initial state:"
./counter.py sum "$A_HOST" "$PORT" "$B_HOST" "$PORT" "$C_HOST" "$PORT" \
  "$EXPECTED" "$TIMEOUT_MS" "$STABLE_POLLS"

echo "Checkpointing local B (and sidecar) via the host receiver, then stopping them."
# The receiver checkpoints with --leave-running, so B keeps serving
# (counter=10) until the explicit stop. A failed checkpoint aborts the
# test before anything is removed.
breakout checkpoint '{"target_id": "counter-b", "export_path": "/tmp/counter-b.tar.zst"}'
if [ "$PROXY" = true ]; then
    breakout checkpoint '{"target_id": "sidecar-b", "export_path": "/tmp/sidecar-b.tar.zst"}'
    breakout stop '{"container_id": "sidecar-b"}'
fi
breakout stop '{"container_id": "counter-b"}'

# /stop is synchronous (curl returns after `podman rm -f` completes), so B is
# already gone here -- no need to probe it. We deliberately do NOT send a
# counter.py STATE to B now: with the sidecar up, that datagram enters the RUDP
# tunnel and is retransmitted forever, resurfacing after restore on the shared
# fixed client port and corrupting a later sum poll.

echo "Sending A -> B while local B is absent."
echo "Sidecar A will intercept this, queue it, and persistently retry behind the scenes."
./counter.py transfer "$A_HOST" "$PORT" "$B_HOST" "$PORT" 7

echo "Restoring local B components onto their macvlan network space."
# counter-b first: sidecar-b joins its network namespace on restore.
breakout restore '{"target_path": "/tmp/counter-b.tar.zst"}'
if [ "$PROXY" = true ]; then
    breakout restore '{"target_path": "/tmp/sidecar-b.tar.zst"}'
fi

echo "Final state check (RUDP ensures no credits vanish; total should stay 30):"
./counter.py sum "$A_HOST" "$PORT" "$B_HOST" "$PORT" "$C_HOST" "$PORT" \
  "$EXPECTED" "$TIMEOUT_MS" "$STABLE_POLLS"
