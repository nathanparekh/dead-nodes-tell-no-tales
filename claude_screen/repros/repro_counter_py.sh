#!/bin/sh
# Runtime proof that the value-conservation / auth defects SURVIVE the counter.c -> counter.py
# rewrite (merged 2026-06-09). Runs in python:3.11-slim; repo mounted at /work.
set -u
cp /work/src/counter.py /tmp/counter.py
chmod +x /tmp/counter.py

echo "### Start node A on 127.0.0.1:5000 with balance 10 (no node B exists)"
python3 /tmp/counter.py node A 5000 10 &
NODE=$!
sleep 1

echo "--- initial state:"
python3 /tmp/counter.py state 127.0.0.1 5000

echo
echo "### C1: non-atomic transfer to an UNREACHABLE destination (counter.py:70,74,77)"
python3 /tmp/counter.py transfer 127.0.0.1 5000 127.0.0.1 5999 7
echo "transfer exit=$?  (reports OK)"
echo "--- A after the 'successful' transfer:"
python3 /tmp/counter.py state 127.0.0.1 5000
echo ">>> counter=3 => the 7 units were DESTROYED (debit, credit to dead host, no rollback)."

echo
echo "### SEC2: unauthenticated RESET (counter.py:78-85)"
python3 /tmp/counter.py reset 127.0.0.1 5000 999999
python3 /tmp/counter.py state 127.0.0.1 5000

echo
echo "### C3: negative transfer amount MINTS funds (counter.py:68,70 - no validation)"
python3 /tmp/counter.py transfer 127.0.0.1 5000 127.0.0.1 5999 -5
python3 /tmp/counter.py state 127.0.0.1 5000
echo ">>> balance increased => negative amounts mint money."

kill "$NODE" 2>/dev/null
echo
echo "### DONE (counter.py)"
