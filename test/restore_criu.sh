#!/bin/bash
# restore_criu.sh <capture_id> [letters...]  — restore LOCAL counters from the
# plain-CRIU images taken by criu_capture.sh.
#
# Counterexample twin of run_restore.sh: no breakout receiver, no restore-mode
# sidecar, no channel replay. Each counter-<letter> is removed and recreated by
# bare `podman container restore`. Whatever was on the wire at capture time is
# in no image and is simply gone; work the counter did after its dump is rolled
# back. Restores run sequentially — order/timing cannot fix anything (the
# inconsistency was baked in at capture time) and serial failures stay legible.
#
# Run per node with that node's letters (default: a b c), like run_restore.sh.
# Afterwards run ./test/verify_sum_noproxy.sh from one node — for this
# counterexample it is EXPECTED to report a VIOLATED total.
set -u

ID="${1:-}"
if [ -z "$ID" ]; then
    echo "usage: $0 <capture_id> [letters...]   (default letters: a b c)" >&2
    exit 1
fi
shift

NODES=("$@")
if [ "${#NODES[@]}" -eq 0 ]; then
    NODES=(a b c)
fi

# Pre-flight: every requested image must exist on THIS host before we touch
# anything (artifacts are per node; a wrong id/letters should fail legibly
# before any counter has been stopped).
missing=()
for node in "${NODES[@]}"; do
    img="/tmp/criu-$ID-counter-$node.tar.zst"
    [ -f "$img" ] || missing+=("$img")
done
if [ "${#missing[@]}" -ne 0 ]; then
    echo "ERROR: missing CRIU image(s) for capture '$ID' on this host:" >&2
    printf '       %s\n' "${missing[@]}" >&2
    avail=$(ls /tmp/criu-*-counter-*.tar.zst 2>/dev/null \
        | sed -E 's#.*/criu-(.*)-counter-([a-z])\.tar\.zst#\1 \2#' \
        | sort \
        | awk '{ids[$1]=ids[$1]" "$2} END{for (i in ids) printf "         %s ->%s\n", i, ids[i]}')
    if [ -n "$avail" ]; then
        echo "Available on this host (capture_id -> node letters):" >&2
        echo "$avail" >&2
    else
        echo "No criu-* images found in /tmp on this host." >&2
    fi
    exit 1
fi

echo "Restoring plain-CRIU capture $ID on this node: ${NODES[*]}"
for node in "${NODES[@]}"; do
    # A leftover proxy-mode sidecar would pin the app's netns and block the rm.
    sudo podman rm -f "sidecar-$node" 2>/dev/null || true
    sudo podman rm -f "counter-$node" 2>/dev/null || true
    echo "[*] restoring counter-$node from /tmp/criu-$ID-counter-$node.tar.zst"
    if ! sudo podman container restore -i "/tmp/criu-$ID-counter-$node.tar.zst" \
            --tcp-established >/dev/null; then
        echo "ERROR: restore of counter-$node failed; aborting" >&2
        exit 1
    fi
done

echo "Restore complete (no channel replay — there is no recorded channel)."
echo "After BOTH nodes have restored, run ./test/verify_sum_noproxy.sh from one"
echo "node; for this counterexample expect it to report a VIOLATED total."
