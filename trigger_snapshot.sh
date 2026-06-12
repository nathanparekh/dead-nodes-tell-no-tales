#!/bin/bash
# trigger_snapshot.sh <node> <snapshot_id>
#
# Initiates a global (Chandy-Lamport) snapshot from the local node. POSTs to the
# LOCAL breakout receiver's /snapshot_trigger, which execs __START_SNAPSHOT__
# into counter-<node>'s netns; that node then floods markers to its peers and
# every node records its OWN piece of the global cut.
#
# IMPORTANT: marker fan-out uses lazily-discovered peers. BEFORE triggering, the
# operator MUST warm EVERY directed pair (A->B, B->C, C->A) so each sidecar has
# learned every peer; otherwise the global cut silently omits a node. See the
# runbook.
#
# The call is synchronous: curl returns once the receiver has dispatched the
# trigger, and a failed call aborts the run.

set -u

BREAKOUT_URL="${BREAKOUT_URL:-http://10.99.0.1:8989}"

NODE="${1:-}"
SNAPSHOT_ID="${2:-}"
if [ -z "$NODE" ] || [ -z "$SNAPSHOT_ID" ]; then
    echo "usage: $0 <node> <snapshot_id>   (e.g. $0 a snap1)" >&2
    exit 1
fi

breakout() { # usage: breakout <endpoint> <json-body>
    # --max-time bounds each call: triggering is quick, but allow headroom for
    # the receiver's exec into the app netns. A dropped/firewalled receiver then
    # fails in seconds, not minutes of SYN retransmits.
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

echo "Reminder: warm EVERY directed pair (A->B, B->C, C->A) BEFORE triggering,"
echo "          or the global cut will silently omit a node."

echo "Triggering snapshot $SNAPSHOT_ID from node $NODE via $BREAKOUT_URL"
breakout snapshot_trigger "{\"node\": \"$NODE\", \"snapshot_id\": \"$SNAPSHOT_ID\"}"

echo "Node $NODE initiated snapshot $SNAPSHOT_ID."
echo "Each node will write its OWN artifact to its LOCAL receiver:"
echo "  /tmp/snapshot-$SNAPSHOT_ID-counter-<node>.json    (channel-state cut)"
echo "  /tmp/snapshot-$SNAPSHOT_ID-counter-<node>.tar.zst  (app CRIU image)"
