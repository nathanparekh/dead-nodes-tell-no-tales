#!/bin/bash
# deploy6_noproxy.sh <A|B>  — deploy THIS node's THREE counters WITHOUT sidecars.
#
# Counterexample twin of deploy6.sh: same 6-counter topology (a,b,c on A;
# d,e,f on B), but build.sh is called in no-proxy mode ("n"), so each counter
# talks raw UDP on the mesh (routable cross-node over the VXLAN overlay) with
# NO sidecar, NO breakout network/receiver, and NO snapshot machinery. Pair
# with ./test/test_6counter_criu.sh, which captures the counters with plain,
# uncoordinated CRIU to show why the sidecar Chandy-Lamport cut is needed.
#
# Run ON EACH node with that node's letter (no SSH):
#   ./test/deploy6_noproxy.sh A    (on A: counter-a/b/c)
#   ./test/deploy6_noproxy.sh B    (on B: counter-d/e/f)
set -eu

case "${1:-}" in
    A|a) SUFFIXES=(a b c) ;;
    B|b) SUFFIXES=(d e f) ;;
    *) echo "usage: $0 <A|B>   (the physical node you are running on)" >&2; exit 1 ;;
esac

# build.sh lives at the repo root (this script is in test/).
cd "$(dirname "$0")/.."

# Sequential like deploy6.sh: every build.sh call builds the shared 'counter'
# image, so running them at once would race the image tag.
for s in "${SUFFIXES[@]}"; do
    echo "=== deploy6_noproxy: bringing up counter-$s (no sidecar) on this node ==="
    # A leftover sidecar from a proxy-mode deploy joins the app's netns, and
    # podman refuses to --replace a container another depends on. build.sh only
    # clears it in proxy mode, so clear it here.
    sudo podman rm -f "sidecar-$s" 2>/dev/null || true
    ./build.sh "$s" "$s" n
done

echo "deploy6_noproxy: this node is running (sidecar-less): ${SUFFIXES[*]/#/counter-}"
