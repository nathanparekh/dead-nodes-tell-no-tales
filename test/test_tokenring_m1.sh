#!/bin/bash
# test_tokenring_m1.sh -- M1 local smoke test: 3 tokenring node processes on
# localhost, no proxy. Positive: one token circulates, verify must PASS.
# Negative: two boot tokens, verify must FAIL (validates the checker).
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
TOKENRING="$DIR/../src/tokenring.py"
LOG=/tmp/tokenring_m1.log

[ -f "$TOKENRING" ] || { echo "missing $TOKENRING"; echo "M1 FAIL"; exit 1; }
: > "$LOG"

PIDS=""
cleanup() {
  kill $PIDS 2>/dev/null
  wait 2>/dev/null
}
trap cleanup EXIT

echo "== positive: single-token ring A(16100) -> B(16101) -> C(16102) -> A =="
python3 "$TOKENRING" node A 16100 127.0.0.1 16101 1 100 >>"$LOG" 2>&1 &
PIDS="$PIDS $!"
python3 "$TOKENRING" node B 16101 127.0.0.1 16102 0 100 >>"$LOG" 2>&1 &
PIDS="$PIDS $!"
python3 "$TOKENRING" node C 16102 127.0.0.1 16100 0 100 >>"$LOG" 2>&1 &
PIDS="$PIDS $!"

echo "letting the token circulate..."
sleep 3
echo "verify (expect PASS):"
python3 "$TOKENRING" verify 10 127.0.0.1 16100 127.0.0.1 16101 127.0.0.1 16102
POS=$?

echo "== negative: two tokens (A and B both boot with HAS_TOKEN=1) on 16200-16202 =="
# Start order C, B, A with staggered holds so the duplicate-epoch outcome is
# robust to several hundred ms of process start skew: C (no token) binds first;
# B forwards its boot token (100ms) before A's token reaches B (600ms), so B
# later witnesses the same epoch 1 that C already witnessed; C's long hold
# (1000ms) keeps B's token away from A until A has forwarded its own boot
# token (otherwise A would absorb it and only one token would circulate).
python3 "$TOKENRING" node C 16202 127.0.0.1 16200 0 1000 >>"$LOG" 2>&1 &
PIDS="$PIDS $!"
python3 "$TOKENRING" node B 16201 127.0.0.1 16202 1 100 >>"$LOG" 2>&1 &
PIDS="$PIDS $!"
python3 "$TOKENRING" node A 16200 127.0.0.1 16201 1 600 >>"$LOG" 2>&1 &
PIDS="$PIDS $!"

echo "letting the duplicate epochs appear..."
sleep 3
echo "verify (expect FAIL):"
python3 "$TOKENRING" verify 10 127.0.0.1 16200 127.0.0.1 16201 127.0.0.1 16202
NEG=$?

if [ "$POS" -eq 0 ] && [ "$NEG" -eq 1 ]; then
  echo "M1 PASS"
  exit 0
else
  echo "positive verify exit=$POS (want 0), negative verify exit=$NEG (want 1)"
  echo "node logs: $LOG"
  echo "M1 FAIL"
  exit 1
fi
