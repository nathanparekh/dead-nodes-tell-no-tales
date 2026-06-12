#!/bin/bash
# deploy6.sh <A|B>  — deploy THIS physical node's THREE counter containers.
#
# The 6-container test puts 3 counters on each of 2 physical nodes:
#
#   physical node A -> counter-a (10.24.24.10), counter-b (10.24.24.11),
#                      counter-c (10.24.24.12)
#   physical node B -> counter-d (10.24.24.13), counter-e (10.24.24.14),
#                      counter-f (10.24.24.15)
#
# Run it ON EACH node with that node's letter (no SSH — each node deploys only
# its own three):  ./test/deploy6.sh A   (on A) ,  ./test/deploy6.sh B  (on B)
#
# Every sidecar is given the FULL 6-member list via MESH_MEMBERS. The snapshot
# marker fan-out and recording set come from MESH_MEMBERS (see config.py /
# snapshot_handler.py), so if a sidecar only knew the default 3 members the
# global cut would SILENTLY drop the other 3 nodes. The control container
# (10.24.24.200) is deliberately NOT a member, so it is never recorded.
set -eu

# All six mesh IPs (a..f -> .10..15). Forwarded to every sidecar by build.sh.
export MESH_MEMBERS=10.24.24.10,10.24.24.11,10.24.24.12,10.24.24.13,10.24.24.14,10.24.24.15

case "${1:-}" in
    A|a) SUFFIXES=(a b c) ;;
    B|b) SUFFIXES=(d e f) ;;
    *) echo "usage: $0 <A|B>   (the physical node you are running on)" >&2; exit 1 ;;
esac

# build.sh lives at the repo root (this script is in test/).
cd "$(dirname "$0")/.."

# Deploy the node's three counters sequentially: every build.sh call builds the
# shared 'counter'/'sidecar' images, so running them at once would race the
# image tags. The real parallelism is across the 2 physical nodes (you run this
# on both at the same time).
for s in "${SUFFIXES[@]}"; do
    echo "=== deploy6: bringing up counter-$s on this node ==="
    ./build.sh "$s" "$s"
done

echo "deploy6: this node is running: ${SUFFIXES[*]/#/counter-}"
