#!/bin/bash
# demo_token_ring.sh — M6 driver for the token-ring checkpoint demo (TOKEN_RING_PLAN.md §9, §11).
#
# Takes ONE Chandy-Lamport snapshot while the token is in flight on the A->B hop
# (held open by tc netem delay), kills all nodes, then restores twice from the
# SAME CRIU images:
#   (a) with the proxy-recorded channel state replayed  -> verify PASS
#   (b) CRIU memory only, no replay                     -> verify FAIL (duplicate epoch)
#
# Run from a repo checkout on any one of the three hosts. Environment:
#   A_SSH/B_SSH/C_SSH   ssh command prefix per host, e.g. "ssh ubuntu@172.31.32.239".
#                       Empty string = that node is THIS host, run locally.
#   A_IP/B_IP/C_IP      mesh IPs           (default 10.24.24.10 / .11 / .12)
#   PORT                app port           (default 5000)
#   NETEM_MS            A->B link delay    (default 5000; must exceed the
#                       trigger latency PLUS the initiator's blocking CRIU
#                       checkpoint, or the token outruns the markers)
#   LOSS_TIMEOUT_MS     loss-recovery timer; MUST match how the nodes were
#                       deployed (default 60000)
#   SNAP_DIR            checkpoint dir on each host (default /var/lib/tokenring-demo)
#   VERIFY_ROUNDS       rounds per verify  (default 30)
#   AGENT_PORT          checkpoint agent   (default 9090)
# Flags:
#   --resting    M3 plumbing check: no netem, snapshot while the token RESTS in
#                a node, restore (a) only, expect PASS.
#   --criu-only  skip restore (a); run only the CRIU-only control (b).

set -u

A_SSH=${A_SSH:-}; B_SSH=${B_SSH:-}; C_SSH=${C_SSH:-}
A_IP=${A_IP:-10.24.24.10}; B_IP=${B_IP:-10.24.24.11}; C_IP=${C_IP:-10.24.24.12}
PORT=${PORT:-5000}
NETEM_MS=${NETEM_MS:-5000}
LOSS_TIMEOUT_MS=${LOSS_TIMEOUT_MS:-60000}
SNAP_DIR=${SNAP_DIR:-/var/lib/tokenring-demo}
VERIFY_ROUNDS=${VERIFY_ROUNDS:-30}
AGENT_PORT=${AGENT_PORT:-9090}

CRIU_ONLY=0; RESTING=0
for arg in "$@"; do
    case "$arg" in
        --criu-only) CRIU_ONLY=1 ;;
        --resting)   RESTING=1 ;;
        *) echo "unknown flag: $arg (known: --resting --criu-only)" >&2; exit 1 ;;
    esac
done
if [ "$CRIU_ONLY" = 1 ] && [ "$RESTING" = 1 ]; then
    echo "--criu-only and --resting are mutually exclusive" >&2; exit 1
fi

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
TMPD="$(mktemp -d /tmp/tokenring-demo.XXXXXX)"

die()    { echo "FATAL: $*" >&2; exit 1; }
banner() { echo; echo "=== stage $1: $2 ==="; }

ssh_prefix() {
    case "$1" in a) echo "$A_SSH" ;; b) echo "$B_SSH" ;; c) echo "$C_SSH" ;; esac
}

# node_run a|b|c <subcommand> [args...] — run node_ctl.sh as root on that node's host.
node_run() {
    local p; p=$(ssh_prefix "$1"); shift
    if [ -z "$p" ]; then
        sudo SNAP_DIR="$SNAP_DIR" bash "$HARNESS_DIR/node_ctl.sh" "$@"
    else
        $p sudo SNAP_DIR="$SNAP_DIR" bash -s -- "$@" < "$HARNESS_DIR/node_ctl.sh"
    fi
}

# host_run a|b|c <command...> — run a raw command on that node's host.
host_run() {
    local p; p=$(ssh_prefix "$1"); shift
    if [ -z "$p" ]; then "$@"; else $p "$@"; fi
}

# app_run <tokenring-cli-args...> — one-shot app container on the mesh.
app_run() {
    sudo podman run --rm --network vlan tokenring "$@"
}

run_verify() {
    app_run verify "$VERIFY_ROUNDS" "$A_IP" "$PORT" "$B_IP" "$PORT" "$C_IP" "$PORT"
}

kill_all() {
    for x in a b c; do node_run "$x" kill "$x" || die "kill failed on $x"; done
}

cleanup() {
    node_run a netem-off a >/dev/null 2>&1 || true
    rm -rf "$TMPD"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
banner 1 "preflight"
for x in a b c; do
    host_run "$x" curl -sf "localhost:$AGENT_PORT/health" >/dev/null \
        || die "checkpoint agent on host $x not answering on :$AGENT_PORT (see harness/README.md)"
    ps_out=$(node_run "$x" ps)
    echo "$ps_out" | grep "tokenring-$x" | grep -q "Up" || die "tokenring-$x is not running on host $x"
    echo "$ps_out" | grep "sidecar-$x"   | grep -q "Up" || die "sidecar-$x is not running on host $x"
    nwords=$(host_run "$x" sudo podman inspect --format '{{.Config.Cmd}}' "tokenring-$x" | wc -w)
    if [ "$nwords" -lt 8 ]; then
        echo "[!] WARNING: tokenring-$x was deployed WITHOUT LOSS_TIMEOUT_MS. The CRIU-only"
        echo "[!] control (restore (b)) will never regenerate a token, so the punchline cannot"
        echo "[!] bite. Redeploy with LOSS_TIMEOUT_MS=$LOSS_TIMEOUT_MS (see build_tokenring.sh)."
    fi
done
echo "[*] baseline verify ($VERIFY_ROUNDS rounds)"
run_verify || die "baseline verify FAILED — fix the live ring before running the demo"

# ---------------------------------------------------------------------------
if [ "$RESTING" = 1 ]; then
    banner 2 "netem (skipped: --resting)"
else
    banner 2 "netem-on: ${NETEM_MS}ms delay on the A->B hop"
    node_run a netem-on a "$B_IP" "$NETEM_MS" || die "netem-on failed on host a"
fi

# ---------------------------------------------------------------------------
banner 3 "position + trigger snapshot"
SID_BEFORE=$(node_run c latest-snapshot || true)
if [ "$RESTING" = 1 ]; then
    echo "[*] waiting for the token to rest in some node (have=1)"
    deadline=$(( $(date +%s) + 60 ))
    while :; do
        held=0
        for ip in "$A_IP" "$B_IP" "$C_IP"; do
            if app_run status "$ip" "$PORT" 2>/dev/null | grep -q "have=1"; then held=1; break; fi
        done
        [ "$held" = 1 ] && break
        [ "$(date +%s)" -lt "$deadline" ] || die "no node reported have=1 within 60s"
    done
else
    echo "[*] waiting for the token to commit to the A->B wire (wait_inflight)"
    sudo podman run --rm --network vlan -v "$HARNESS_DIR:/h:ro" --entrypoint python3 \
        tokenring /h/wait_inflight.py "$A_IP" "$B_IP" "$PORT" 90 \
        || die "wait_inflight timed out — is the ring circulating?"
fi
echo "[*] triggering snapshot from C"
# The nodes' loss timers run from each node's last token FORWARD, which is at
# or before this moment — so take the budget baseline now, not after collect.
T_SNAP=$(date +%s)
node_run c trigger-snapshot c "$A_IP" || die "trigger-snapshot failed on host c"

# ---------------------------------------------------------------------------
banner 4 "collect: wait for checkpoints on all 3 hosts, fetch channel state"
SID=""
deadline=$(( $(date +%s) + 120 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    SID=$(node_run c latest-snapshot || true)
    if [ -n "$SID" ] && [ "$SID" != "$SID_BEFORE" ] \
       && node_run a has-checkpoint a "$SID" \
       && node_run b has-checkpoint b "$SID" \
       && node_run c has-checkpoint c "$SID"; then
        break
    fi
    SID=""
    sleep 2
done
[ -n "$SID" ] || die "no complete checkpoint set within 120s (agent logs? sidecar can reach :$AGENT_PORT?)"
echo "[*] snapshot id: $SID"
node_run a netem-off a || true
for x in a b c; do
    # A sidecar writes its JSON only once it has markers from BOTH peers; B's
    # waits on A's netem-delayed marker, so poll briefly instead of racing it.
    tries=15
    while :; do
        node_run "$x" fetch-channels "$x" "$SID" > "$TMPD/channels-$x.json" \
            || die "fetch-channels failed on $x"
        grep -q '"snapshot_id"' "$TMPD/channels-$x.json" && break
        tries=$(( tries - 1 ))
        [ "$tries" -gt 0 ] || break   # give up; the bite check will explain
        sleep 1
    done
    echo "[*] fetched channels-$x.json ($(wc -c < "$TMPD/channels-$x.json") bytes)"
done

# ---------------------------------------------------------------------------
if [ "$RESTING" = 1 ]; then
    banner 5 "bite check (skipped: --resting)"
else
    banner 5 "bite check: the in-flight TOKEN must be in B's recorded channel state"
    if python3 -c 'import json,base64,sys; d=json.load(open(sys.argv[1])); msgs=[m for ch in d.get("channels",{}).values() for m in ch]; sys.exit(0 if any(base64.b64decode(m["payload_b64"]).startswith(b"TOKEN ") for m in msgs) else 1)' "$TMPD/channels-b.json"; then
        echo "[*] bite check OK: TOKEN recorded as channel state (CRIU cannot see it)"
    else
        echo "[!] bite check FAILED: no TOKEN in B's channel state. The token was resting in"
        echo "[!] a node when the markers landed, so this snapshot does not exercise channel"
        echo "[!] state. Raise NETEM_MS (currently $NETEM_MS) and re-run."
        echo "[!] The live ring is left running."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
banner 6 "kill all three nodes"
kill_all

# ---------------------------------------------------------------------------
RES_A="skipped"
if [ "$CRIU_ONLY" = 1 ]; then
    banner 7 "restore (a) (skipped: --criu-only)"
else
    banner 7 "restore (a): CRIU images + channel replay -> expect PASS"
    for x in a b c; do node_run "$x" restore "$x" "$SID" || die "restore failed on $x"; done
    for x in a b c; do
        case "$x" in a) ip=$A_IP ;; b) ip=$B_IP ;; c) ip=$C_IP ;; esac
        sudo podman run --rm --network vlan -v "$HARNESS_DIR:/h:ro" -v "$TMPD:/replay:ro" \
            --entrypoint python3 tokenring /h/replay_channels.py "/replay/channels-$x.json" "$ip" \
            || die "replay failed for $x"
    done
    elapsed=$(( $(date +%s) - T_SNAP ))
    budget=$(( LOSS_TIMEOUT_MS / 1000 ))
    if [ "$elapsed" -ge $(( budget - 10 )) ]; then
        echo "[!] WARNING: kill->restore+replay took ${elapsed}s of the ${budget}s LOSS_TIMEOUT_MS"
        echo "[!] budget. CRIU does not virtualize the wall clock, so restored nodes may have"
        echo "[!] already regenerated a token — a FAIL here may be harness slowness, not a bug."
    else
        echo "[*] ${elapsed}s since checkpoint (budget ${budget}s) — loss timers are quiet"
    fi
    if run_verify; then RES_A="PASS"; else RES_A="FAIL"; fi
    echo "[*] restore (a) verify: $RES_A (expected PASS)"
    if [ "$RESTING" = 1 ]; then
        echo "[*] --resting: leaving the restored ring running"
    else
        kill_all
    fi
fi

# ---------------------------------------------------------------------------
RES_B="skipped"
if [ "$RESTING" = 1 ]; then
    banner 8 "restore (b) (skipped: --resting)"
else
    banner 8 "restore (b): CRIU images only, NO replay -> expect FAIL"
    for x in a b c; do node_run "$x" restore "$x" "$SID" || die "restore failed on $x"; done
    wake=$(( T_SNAP + LOSS_TIMEOUT_MS / 1000 + 5 ))
    now=$(date +%s)
    if [ "$now" -lt "$wake" ]; then
        echo "[*] sleeping $(( wake - now ))s for the loss-recovery timers to fire"
        sleep $(( wake - now ))
    fi
    if run_verify; then RES_B="PASS"; else RES_B="FAIL"; fi
    echo "[*] restore (b) verify: $RES_B (expected FAIL)"
fi

# ---------------------------------------------------------------------------
banner 9 "summary"
rc=0
printf "%-15s %-10s %s\n" "restore" "expected" "got"
if [ "$CRIU_ONLY" = 0 ]; then
    printf "%-15s %-10s %s\n" "(a) replay" "PASS" "$RES_A"
    [ "$RES_A" = "PASS" ] || rc=1
fi
if [ "$RESTING" = 0 ]; then
    printf "%-15s %-10s %s\n" "(b) criu-only" "FAIL" "$RES_B"
    [ "$RES_B" = "FAIL" ] || rc=1
fi
if [ "$RESTING" = 0 ]; then
    echo
    echo "Note: restore (b)'s violated ring is left running (duplicate epochs and all)."
    echo "Redeploy a clean ring with build_tokenring.sh on each host (token-less nodes first)."
fi
exit $rc
