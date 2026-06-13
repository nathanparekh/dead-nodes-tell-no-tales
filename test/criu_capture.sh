#!/bin/bash
# criu_capture.sh <capture_id> <letters...>  — plain-CRIU capture of LOCAL counters.
#
# The counterexample's "snapshot": checkpoint each local counter-<letter> with
# bare `podman container checkpoint` (CRIU), --leave-running so the live system
# is not disturbed. There is NO marker protocol and NO channel recording: a
# CREDIT that is on the wire when the dump happens is in NEITHER the sender's
# image (already debited) nor the receiver's (not yet delivered), so its value
# vanishes on restore. All requested containers are checkpointed IN PARALLEL,
# i.e. as close to "simultaneous" as naive CRIU can get — and the resulting
# cut is still not consistent.
#
# Artifacts: /tmp/criu-<capture_id>-counter-<letter>.tar.zst (LOCAL to this
# node, like the snapshot- artifacts; the criu- prefix keeps the two restore
# paths from ever seeing each other's images).
#
# Run per node with that node's letters (no SSH), e.g. on A: $0 criu6 a b c
set -u

if [ "$#" -lt 2 ]; then
    echo "usage: $0 <capture_id> <letters...>   (e.g. $0 criu6 a b c)" >&2
    exit 1
fi
ID="$1"; shift

pids=() names=()
for x in "$@"; do
    art="/tmp/criu-$ID-counter-$x.tar.zst"
    echo "[*] checkpointing counter-$x -> $art (parallel)"
    sudo podman container checkpoint "counter-$x" -e "$art" \
        --tcp-established --leave-running >/dev/null &
    pids+=($!); names+=("counter-$x")
done

fail=0
for i in "${!pids[@]}"; do
    if ! wait "${pids[$i]}"; then
        echo "ERROR: checkpoint of ${names[$i]} failed" >&2
        fail=1
    fi
done
[ "$fail" -eq 0 ] && echo "captured (plain CRIU, id $ID): $*"
exit "$fail"
