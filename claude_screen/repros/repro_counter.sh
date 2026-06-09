#!/bin/sh
# Runtime proof of counter.c value-conservation / auth defects.
# Runs inside a container that has gcc (dnt-tools). Repo mounted at /work.
set -u
echo "### Building counter.c"
gcc -Wall -Wextra -Werror -O2 -o /tmp/counter /work/src/counter.c || { echo "build failed"; exit 1; }

echo "### Start node A on 127.0.0.1:5000 with balance 10 (no node B exists)"
/tmp/counter node A 5000 10 &
NODE=$!
sleep 1

echo "--- initial state:"
/tmp/counter state 127.0.0.1 5000

echo
echo "### BUG: non-atomic transfer to an UNREACHABLE destination."
echo "### Transfer 7 from A(5000) to a DEAD node 127.0.0.1:5999 (nothing listening)."
echo "### A debits itself and fires a CREDIT at the dead host, then replies OK."
/tmp/counter transfer 127.0.0.1 5000 127.0.0.1 5999 7
echo "transfer exit=$?  (note: it reports OK)"

echo
echo "--- state of A AFTER the 'successful' transfer:"
/tmp/counter state 127.0.0.1 5000
echo ">>> If counter=3, the 7 units were DESTROYED: A debited, credit went to a"
echo ">>> dead host, no rollback, no app-level retry. Money is not conserved."

echo
echo "### BUG: no authentication — any UDP client can RESET another node's balance."
/tmp/counter reset 127.0.0.1 5000 999999
/tmp/counter state 127.0.0.1 5000
echo ">>> An unauthenticated RESET arbitrarily rewrote the balance."

echo
echo "### BUG: any client can CREDIT (mint) funds with no authentication."
printf '' | /tmp/counter transfer 127.0.0.1 5000 127.0.0.1 5999 -5
echo "(transfer of negative amount: A's balance can be increased by a 'transfer')"
/tmp/counter state 127.0.0.1 5000
echo ">>> Negative transfer amount INCREASES the sender's balance (no validation)."

kill "$NODE" 2>/dev/null
echo
echo "### DONE"
