#!/bin/bash
# deploy6.sh <A|B|C>  — deploy THIS physical node's TWO counter containers.
#
# The 6-container test puts 2 counters on each of the 3 physical nodes:
#
#   physical node A -> counter-a (10.24.24.10) + counter-d (10.24.24.13)
#   physical node B -> counter-b (10.24.24.11) + counter-e (10.24.24.14)
#   physical node C -> counter-c (10.24.24.12) + counter-f (10.24.24.15)
#
# Run it ON EACH node with that node's letter (no SSH — each node deploys only
# its own pair):  ./test/deploy6.sh A   (on A) ,  ./test/deploy6.sh B  (on B) ...
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
    A|a) PAIR=(a d) ;;
    B|b) PAIR=(b e) ;;
    C|c) PAIR=(c f) ;;
    *) echo "usage: $0 <A|B|C>   (the physical node you are running on)" >&2; exit 1 ;;
esac

# build.sh lives at the repo root (this script is in test/).
cd "$(dirname "$0")/.."

# Deploy the node's two counters sequentially: both build.sh calls build the
# shared 'counter'/'sidecar' images, so running them at once would race the
# image tags. The real parallelism is across the 3 physical nodes (you run this
# on all three at the same time).
for s in "${PAIR[@]}"; do
    echo "=== deploy6: bringing up counter-$s on this node ==="
    ./build.sh "$s" "$s"
done

echo "deploy6: this node is running counter-${PAIR[0]} and counter-${PAIR[1]}."
