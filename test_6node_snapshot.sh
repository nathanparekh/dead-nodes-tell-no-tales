#!/bin/bash
# test_6node_snapshot.sh [snapshot_id] [initiator_letter] [per_node] [before_s] [after_s]
#
# Control-node orchestrator for the 6-container Chandy-Lamport snapshot-under-load
# test. Runs ON the node that hosts the mesh-ctl control container AND the
# initiator counter (default letter `a` => node A). Assumes the six containers +
# sidecars are already deployed across the three nodes (per RUNBOOK-6node.md) and
# this node's local breakout receiver is up.
#
# It drives money-transfer load among the six counters BEFORE, DURING, and AFTER
# a global snapshot, takes the cut mid-load, then either auto-collects every
# node's artifact (env NODES_SSH) and runs verify_snapshot.py, or prints
# copy-pasteable manual scp + verify instructions.
#
# Defaults: snapshot_id=snap6, initiator_letter=a, per_node=10, before_s=8, after_s=8.
# Env NODES_SSH: space-separated ssh targets for the OTHER two nodes, e.g.
#   NODES_SSH="user@nodeB user@nodeC"

set -u

SNAPSHOT_ID="${1:-snap6}"
INITIATOR="${2:-a}"
PER_NODE="${3:-10}"
BEFORE_S="${4:-8}"
AFTER_S="${5:-8}"

EXPECTED=$(( PER_NODE * 6 ))
GLOB="/tmp/snapshot-${SNAPSHOT_ID}-counter-*.json"

banner() { echo; echo "=== $* ==="; }

# 1. Establish + verify the starting total (= 6*per_node). Abort if it fails.
banner "1/8 bootstrap6: reset all six to ${PER_NODE}, warm the ring, verify total=${EXPECTED}"
if ! ./mesh_ctl.sh bootstrap6 "$PER_NODE"; then
    echo "ERROR: bootstrap6 failed; aborting" >&2
    exit 1
fi

# 2. Start continuous load in the BACKGROUND, spanning before + during + after.
#    The load self-terminates after LOAD_SECS, but step 6 kills it explicitly, so
#    size LOAD_SECS with a generous margin: the synchronous trigger (step 4) can
#    block for several seconds (CRIU + marker fan-out across six sidecars), and
#    that time must NOT eat into the after-the-cut window. Killed on any exit.
LOAD_SECS=$(( BEFORE_S + AFTER_S + 30 ))
banner "2/8 starting background load for ${LOAD_SECS}s (transfers before+during+after the cut)"
./mesh_ctl.sh load "$LOAD_SECS" 100 1 &
LOAD_PID=$!
trap 'kill "$LOAD_PID" 2>/dev/null || true' EXIT
echo "[*] load running as PID $LOAD_PID"

# 3. Let transactions flow BEFORE the cut.
banner "3/8 load flowing for ${BEFORE_S}s before the snapshot"
sleep "$BEFORE_S"

# 4. Trigger the global snapshot from the local receiver. Abort if it fails.
banner "4/8 trigger_snapshot ${SNAPSHOT_ID} from node ${INITIATOR} (mid-load)"
if ! ./trigger_snapshot.sh "$INITIATOR" "$SNAPSHOT_ID"; then
    echo "ERROR: trigger_snapshot failed; aborting" >&2
    exit 1
fi

# 5. Let transactions keep flowing AFTER the cut.
banner "5/8 load flowing for ${AFTER_S}s after the snapshot"
sleep "$AFTER_S"

# 6. Stop the load. It also self-terminates by duration; reap it so the EXIT
#    trap has nothing left to kill.
banner "6/8 stopping background load"
kill "$LOAD_PID" 2>/dev/null || true
wait "$LOAD_PID" 2>/dev/null || true

# 7. Show this node's OWN artifacts and a LIVE conservation sanity check. Each
#    node holds only its own two JSONs; the rest are gathered in step 8. The
#    live sum stays at EXPECTED because every transfer conserves money.
banner "7/8 local artifacts on this node + live conservation check (expect ${EXPECTED})"
ls -l $GLOB 2>/dev/null || echo "[!] no local artifacts matched $GLOB"
./mesh_ctl.sh sum6 "$EXPECTED" || true

# 8. Collect every node's artifact into one dir and verify, or print manual
#    instructions when NODES_SSH is not provided.
banner "8/8 collect + verify the snapshot contents"
SNAPDIR="./snap-${SNAPSHOT_ID}"

if [ -n "${NODES_SSH:-}" ]; then
    echo "[*] NODES_SSH set; auto-collecting into ${SNAPDIR} and verifying"
    mkdir -p "$SNAPDIR"

    # This node's own artifacts.
    cp $GLOB "$SNAPDIR"/ 2>/dev/null || echo "[!] no local artifacts to copy from $GLOB"

    # The other two nodes' artifacts.
    for t in $NODES_SSH; do
        echo "[*] scp from $t"
        scp "$t:${GLOB}" "$SNAPDIR"/ || echo "[!] scp from $t failed (continuing)"
    done

    echo "[*] running verify_snapshot.py on ${SNAPDIR}"
    python3 verify_snapshot.py "$SNAPDIR" "$SNAPSHOT_ID"
    exit $?
fi

# No NODES_SSH: print copy-pasteable manual collect + verify instructions. Each
# node holds only its own two artifacts, so all three must be gathered.
cat <<EOF
NODES_SSH not set -- collect all six artifacts manually, then verify.

  # 1. gather every node's two JSONs into one directory on this node:
  mkdir -p ${SNAPDIR}
  cp ${GLOB} ${SNAPDIR}/                    # this node's own artifacts
  scp user@nodeB:${GLOB} ${SNAPDIR}/        # node B's two artifacts
  scp user@nodeC:${GLOB} ${SNAPDIR}/        # node C's two artifacts

  # 2. verify the cut's contents (expect 6/6 complete, 30/30 channels consistent):
  python3 verify_snapshot.py ${SNAPDIR} ${SNAPSHOT_ID}

  # (or re-run with NODES_SSH set to auto-collect+verify:)
  NODES_SSH="user@nodeB user@nodeC" $0 ${SNAPSHOT_ID} ${INITIATOR} ${PER_NODE} ${BEFORE_S} ${AFTER_S}
EOF
