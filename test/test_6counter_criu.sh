#!/bin/bash
# test_6counter_criu.sh [capture_id]  — COUNTEREXAMPLE: the 6-container Counter
# test under the same continuous load as test_6counter.sh, but with NO sidecar
# proxies and NO Chandy-Lamport cut. The "snapshot" is plain per-container CRIU
# (podman container checkpoint), taken while traffic is flowing.
#
# Topology: identical to test_6counter.sh — 6 counters (a..f, IPs .10..15),
# 3 per physical node across 2 nodes — but deployed with
# ./test/deploy6_noproxy.sh, so the counters talk raw UDP on the mesh (routable
# cross-node over the VXLAN overlay) with no sidecars, no breakout receiver,
# and no snapshot machinery.
#
# What it does:
#   1. Reset all 6 counters to 10 (total 60) and warm the full ring (now just a
#      raw end-to-end reachability check — there are no sidecars to learn peers).
#   2. Start the SAME continuous multithreaded ring load (each transfer nets to
#      zero, so the live total stays 60).
#   3. While the load is flowing, checkpoint THIS node's counters with bare
#      CRIU — all of them IN PARALLEL, i.e. as close to "simultaneous" as an
#      uncoordinated capture can get. Nothing records channel state: a CREDIT
#      on the wire at dump time lands in NEITHER image.
#   4. Keep the load flowing AFTER the capture, then stop it and verify the
#      LIVE total is still 60 (--leave-running: the capture did not disturb the
#      running system, so any loss seen after restore is the capture's fault,
#      not the load's).
#   5. Print the per-node restore steps. After ./test/restore_criu.sh on each
#      node, ./test/verify_sum_noproxy.sh is EXPECTED to report a VIOLATED
#      total — that failure is the counterexample, to be contrasted with
#      test_6counter.sh + run_restore.sh where the total survives.
#
# Like test_6counter.sh this driver runs on ONE node (physical A) with no SSH.
# Capture node B's three with `./test/criu_capture.sh <id> d e f` over there —
# while this driver's load is still flowing (give yourself slack with
# POST_SNAP_SECS=30) for the canonical lost-in-flight demonstration, though ANY
# timing yields an inconsistent cut: there is no coordination protocol, which
# is the point.
set -u

cd "$(dirname "$0")/.."

SNAP_ID="${1:-criu6}"
PORT=5000
PER_NODE=10
MESH_NET="${MESH_NET:-vlan}"
CTL=mesh-ctl-np           # sidecar-LESS control container. mesh_ctl.sh's
CTL_IP=10.24.24.201       # mesh-ctl carries a TPROXY sidecar that would tunnel
                          # RUDP at counters with nothing to de-tunnel it.
LOCAL_LETTERS=(${LOCAL_LETTERS:-a b c})   # this node's counters (physical A)
IPS=(10.24.24.10 10.24.24.11 10.24.24.12 10.24.24.13 10.24.24.14 10.24.24.15)
N=${#IPS[@]}
TOTAL=$(( PER_NODE * N ))    # 60

# Same load knobs as test_6counter.sh (see there for why it is multithreaded:
# one-at-a-time transfers leave the channels ~always empty, and an empty
# channel would let even an uncoordinated capture look consistent by luck).
LOAD_THREADS="${LOAD_THREADS:-8}"       # concurrent in-flight transfer streams
PRE_SNAP_SECS="${PRE_SNAP_SECS:-3}"     # load-only seconds before the capture
POST_SNAP_SECS="${POST_SNAP_SECS:-5}"   # KEEP operating this long AFTER the capture
LOAD_MAX_SECS="${LOAD_MAX_SECS:-120}"   # hard cap so the blaster can never run forever
STOP_FILE="/tmp/stop_load_$SNAP_ID"     # touch (in the control) to stop the load

# Run a counter.py verb inside the already-running control container.
ctl() { sudo podman exec "$CTL" ./counter.py "$@"; }

# Sum the 6 counters via `state` (counter.py `sum` only does 3). Echoes the
# total, or "MISSING" and returns 1 if any node didn't answer.
total6() {
    local s=0 ip out v
    for ip in "${IPS[@]}"; do
        out=$(ctl state "$ip" "$PORT" 2>/dev/null)   # "STATE <name> counter=<v>"
        case "$out" in
            *counter=*) v=${out##*counter=}; v=${v%%[!0-9-]*} ;;
            *) echo "MISSING:$ip"; return 1 ;;
        esac
        [ -z "$v" ] && { echo "MISSING:$ip"; return 1; }
        s=$((s + v))
    done
    echo "$s"
}

# Poll the total until it settles at $1 (a heavy concurrent load leaves many
# credits in flight, so give them time to drain after the load stops).
verify_total() {
    local want=$1 t
    for _ in $(seq 1 40); do
        t=$(total6)
        echo "    total=$t (want $want)"
        [ "$t" = "$want" ] && return 0
        sleep 0.5
    done
    return 1
}

# Same multithreaded blaster as test_6counter.sh, run inside the sidecar-less
# control container. Fire-and-forget TRANSFERs around the ring; every transfer
# debits one node and credits the next, so the global total stays conserved
# regardless of where the run is cut off. Stopped via a sentinel file, with
# LOAD_MAX_SECS as a backstop.
start_load() {
    sudo podman exec "$CTL" rm -f "$STOP_FILE" 2>/dev/null || true
    sudo podman exec -i "$CTL" python3 - \
        "$LOAD_MAX_SECS" "$LOAD_THREADS" "$STOP_FILE" "${IPS[@]}" <<'PY' >/dev/null 2>&1 &
import socket, sys, threading, time, random, os
cap = float(sys.argv[1]); nthreads = int(sys.argv[2]); stop = sys.argv[3]; members = sys.argv[4:]
PORT = 5000
deadline = time.time() + cap
def worker():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    n = len(members)
    while time.time() < deadline and not os.path.exists(stop):
        i = random.randrange(n)
        frm, to = members[i], members[(i + 1) % n]
        try:
            s.sendto(f"TRANSFER tx123 {to} {PORT} 1".encode(), (frm, PORT))
        except OSError:
            pass
        time.sleep(0.01)
ts = [threading.Thread(target=worker) for _ in range(nthreads)]
for t in ts: t.start()
for t in ts: t.join()
PY
    LOAD_PID=$!
}

# Stop the load: drop the sentinel, then reap the backgrounded podman exec.
# Idempotent — safe to call from the trap.
stop_load() {
    sudo podman exec "$CTL" touch "$STOP_FILE" 2>/dev/null || true
    [ -n "${LOAD_PID:-}" ] && wait "$LOAD_PID" 2>/dev/null
}

# 1. Bring up the sidecar-less control container. Always RECREATE it: a fresh
#    netns starts with an empty ARP cache, and its ARP requests re-announce its
#    MAC to every counter — the no-sidecar substitute for test_6counter.sh's
#    `ip neigh flush` healing (a previously restored counter has a new MAC).
echo "[*] Bringing up sidecar-less control container $CTL @ $CTL_IP..."
if ! sudo podman image exists test-runner; then
    sudo podman build --network=host -t test-runner -f Containerfile.test .
fi
sudo podman run -d --replace --name "$CTL" \
    --network "${MESH_NET}:ip=$CTL_IP" \
    --entrypoint sleep test-runner infinity >/dev/null

echo "[*] Resetting all 6 nodes to $PER_NODE..."
for ip in "${IPS[@]}"; do ctl reset "$ip" "$PORT" "$PER_NODE" >/dev/null; done

# Warm the full ring — with raw UDP this is purely an end-to-end reachability
# check across both physical nodes before the load starts.
echo "[*] Warming the ring a->b->c->d->e->f->a..."
for ((i = 0; i < N; i++)); do
    ctl transfer "${IPS[i]}" "$PORT" "${IPS[(i + 1) % N]}" "$PORT" 1 >/dev/null
done

echo "[*] Pre-load check: total should settle at $TOTAL"
verify_total "$TOTAL" || { echo "FAIL: counters did not reach $TOTAL before load"; exit 1; }

# 2. Start the multithreaded load. The trap stops it on any early exit.
start_load
trap stop_load EXIT
echo "[*] Load generator running ($LOAD_THREADS threads, pid $LOAD_PID);"
echo "    letting traffic flow BEFORE the capture..."
sleep "$PRE_SNAP_SECS"

# 3. Capture WHILE the load is saturating the channels: bare CRIU, all local
#    counters dumped in parallel. No markers, no channel recording — unlike
#    trigger_snapshot.sh there is no global cut to wait for; when the
#    checkpoint commands return, the "capture" is all there will ever be.
echo "[*] Plain-CRIU capture '$SNAP_ID' of ${LOCAL_LETTERS[*]} (parallel) while load continues..."
echo "    (credits on the wire right now are in NEITHER image and will be"
echo "     missing after restore — nothing records channel state)"
if ! ./test/criu_capture.sh "$SNAP_ID" "${LOCAL_LETTERS[@]}"; then
    echo "FAIL: plain-CRIU capture failed"
    exit 1
fi

# 4. Keep operating ACROSS the capture, mirroring test_6counter.sh: the system
#    keeps processing operations after the dump (which the restore will later
#    roll back — uncoordinated images cannot agree on a point in time).
echo "[*] Capture done; KEEPING operations running for ${POST_SNAP_SECS}s after it..."
echo "    (to capture node B under this same load, run there now:"
echo "         ./test/criu_capture.sh $SNAP_ID d e f )"
sleep "$POST_SNAP_SECS"

echo "[*] Stopping load..."
stop_load; trap - EXIT
echo "[*] Load stopped; letting in-flight credits drain..."
sleep 1

# 5. The LIVE system must still conserve the total: the capture was
#    --leave-running and touched nothing. Any loss observed after restore is
#    therefore the capture's fault, not the load's.
echo "[*] Post-load check: LIVE total must return to $TOTAL"
if verify_total "$TOTAL"; then
    echo "PASS: live total conserved at $TOTAL — the plain-CRIU capture did not disturb"
    echo "      the running system. The counterexample shows up at RESTORE time:"
else
    echo "FAIL: live total did not return to $TOTAL after the load."
    exit 1
fi

echo
echo "Capture '$SNAP_ID' artifacts are PER NODE (on each node's local /tmp):"
echo "    /tmp/criu-$SNAP_ID-counter-<letter>.tar.zst   (bare CRIU image, no channel state)"
echo "If node B has not captured yet, run there: ./test/criu_capture.sh $SNAP_ID d e f"
echo "(any timing works — with no coordination the six images can never form a"
echo "consistent cut; capturing under load maximizes the lost in-flight credits)."
echo
echo "To demonstrate the counterexample:"
echo "    node A:   ./test/restore_criu.sh $SNAP_ID a b c"
echo "    node B:   ./test/restore_criu.sh $SNAP_ID d e f"
echo "    either:   ./test/verify_sum_noproxy.sh        # EXPECT: VIOLATED (total != $TOTAL)"
echo "Contrast with test_6counter.sh + run_restore.sh + verify_sum.sh, where the"
echo "sidecar Chandy-Lamport cut + channel replay keeps the total at $TOTAL."
