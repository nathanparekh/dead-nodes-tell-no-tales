#!/usr/bin/env bash
# test_workqueue_local.sh -- localhost smoke test for src/workqueue.py
#
# No containers, no sidecars: 1 coordinator + 2 workers on 127.0.0.1.
#   1. start workers first, then coordinator (a job submitted before its
#      worker binds is lost forever -- by design the app never recovers it)
#   2. submit jobs 1..10, verify 10 must PASS
#   3. duplicate "JOB 3" datagram to the worker that completed it; its done
#      CSV must be unchanged (seen_job dedup) and verify 10 must still PASS
# Final line: "SMOKE PASS" (exit 0) or "SMOKE FAIL" (exit 1).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WQ="$SCRIPT_DIR/../src/workqueue.py"

COORD_PORT=7100
W1_PORT=7101
W2_PORT=7102
PROC_DELAY_MS=100

FAILED=0
PIDS=()
LOGDIR="$(mktemp -d)"

cleanup() {
    for pid in "${PIDS[@]:-}"; do
        [ -n "$pid" ] || continue
        kill "$pid" >/dev/null 2>&1 || true
    done
    wait >/dev/null 2>&1 || true
    rm -rf "$LOGDIR"
}
trap cleanup EXIT

fail() {
    echo "CHECK FAIL: $*"
    FAILED=1
}

dump_logs() {
    for log in coord w1 w2; do
        if [ -f "$LOGDIR/$log.log" ]; then
            echo "--- $log.log ---"
            cat "$LOGDIR/$log.log"
        fi
    done
}

finish() {
    if [ "$FAILED" -eq 0 ]; then
        echo "SMOKE PASS"
        exit 0
    else
        dump_logs
        echo "SMOKE FAIL"
        exit 1
    fi
}

if [ ! -f "$WQ" ]; then
    echo "missing $WQ"
    FAILED=1
    finish
fi

# --- 1. startup: workers first, then coordinator ---------------------------
echo "starting worker w1 on udp/$W1_PORT and worker w2 on udp/$W2_PORT"
python3 "$WQ" worker w1 "$W1_PORT" "$PROC_DELAY_MS" 127.0.0.1 "$COORD_PORT" >"$LOGDIR/w1.log" 2>&1 &
PIDS+=($!)
python3 "$WQ" worker w2 "$W2_PORT" "$PROC_DELAY_MS" 127.0.0.1 "$COORD_PORT" >"$LOGDIR/w2.log" 2>&1 &
PIDS+=($!)

echo "starting coordinator on udp/$COORD_PORT"
python3 "$WQ" coordinator coord "$COORD_PORT" 127.0.0.1 "$W1_PORT" 127.0.0.1 "$W2_PORT" >"$LOGDIR/coord.log" 2>&1 &
PIDS+=($!)

# brief sleep so every socket is bound BEFORE any submit, then confirm via
# STATUS -- a JOB sent to an unbound worker port is lost forever by design
sleep 1
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if python3 "$WQ" status 127.0.0.1 "$COORD_PORT" >/dev/null 2>&1 \
       && python3 "$WQ" status 127.0.0.1 "$W1_PORT" >/dev/null 2>&1 \
       && python3 "$WQ" status 127.0.0.1 "$W2_PORT" >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 0.5
done
if [ "$ready" -ne 1 ]; then
    fail "coordinator/workers did not answer STATUS after startup"
    finish
fi
echo "all three nodes answering STATUS"

# --- 2. submit jobs 1..10 and verify ---------------------------------------
echo "submitting jobs 1..10"
for i in 1 2 3 4 5 6 7 8 9 10; do
    python3 "$WQ" submit 127.0.0.1 "$COORD_PORT" "$i"
done

if python3 "$WQ" verify 10 127.0.0.1 "$W1_PORT" 127.0.0.1 "$W2_PORT"; then
    echo "CHECK PASS: verify 10 after submit"
else
    fail "verify 10 after submit"
fi

# --- 3. dedup check: duplicate JOB 3 to whichever worker completed it ------
# worker STATUS reply: "STATUS <name> done=<csv>"; exact-match jobid in csv
has_job() {
    local csv="${1#*done=}"
    local j
    local IFS=','
    for j in $csv; do
        [ "$j" = "$2" ] && return 0
    done
    return 1
}

w1_before="$(python3 "$WQ" status 127.0.0.1 "$W1_PORT")"
w2_before="$(python3 "$WQ" status 127.0.0.1 "$W2_PORT")"
echo "w1: $w1_before"
echo "w2: $w2_before"

target_port=""
if has_job "$w1_before" 3; then
    target_name=w1; target_port=$W1_PORT; before="$w1_before"
elif has_job "$w2_before" 3; then
    target_name=w2; target_port=$W2_PORT; before="$w2_before"
else
    fail "job 3 not in any worker's done set"
fi

if [ -n "$target_port" ]; then
    echo "sending duplicate 'JOB 3' datagram to $target_name (udp/$target_port)"
    python3 -c "import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.sendto(b'JOB 3', ('127.0.0.1', $target_port)); s.close()"
    sleep 0.5

    after="$(python3 "$WQ" status 127.0.0.1 "$target_port")"
    if [ -n "$after" ] && [ "$after" = "$before" ]; then
        echo "CHECK PASS: dedup -- $target_name done CSV unchanged"
    else
        fail "dedup: $target_name status changed: before='$before' after='$after'"
    fi

    if python3 "$WQ" verify 10 127.0.0.1 "$W1_PORT" 127.0.0.1 "$W2_PORT"; then
        echo "CHECK PASS: verify 10 after duplicate JOB"
    else
        fail "verify 10 after duplicate JOB"
    fi
fi

finish
