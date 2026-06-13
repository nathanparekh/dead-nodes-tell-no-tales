#!/bin/bash
# local_mesh.sh
#
# Run the whole 3-node Chandy-Lamport snapshot + restore flow on ONE Linux host
# (a single EC2 box) with podman + CRIU. The multi-host stack is already
# host-local for every podman/CRIU op (the breakout receiver) and the proxy
# pins no NICs, so the ONLY thing that's genuinely multi-host is the mesh
# network -- macvlan can't do same-host container<->container. So here the mesh
# is a plain BRIDGE named `vlan` (the name build.sh / mesh_ctl.sh already
# default to), and every existing script runs verbatim with no env vars.
#
# Usage (run on the EC2 host, from the repo root):
#   ./local_mesh.sh up               # create bridge, deploy a/b/c, warm + verify total=30
#   ./local_mesh.sh snapshot <id>    # traffic across the cut, restore a/b/c, verify total=30
#   ./local_mesh.sh delayed  <id>    # like snapshot, but DELAY (+light loss) during the cut
#   ./local_mesh.sh dropped  <id>    # like snapshot, but DROP packets during cut AND restore
#   ./local_mesh.sh down             # tear everything down (idempotent)
#
# All three cut-tests drive live ring traffic across the cut so the snapshot has
# real in-flight channel state to capture. Conservation of the total (==30) is
# the correctness signal: RUDP retransmit + a consistent global cut preserve it
# despite delay/loss; a dropped in-flight credit would settle below 30.
#
# Env: MESH_NET (default "vlan"),
#      NETEM_DELAY (default "delay 200ms 50ms loss 10%")  -- the `delayed` test,
#      NETEM_DROP  (default "loss 25%")                    -- the `dropped` test.

set -u

cd "$(dirname "$0")" || exit 1

BREAKOUT_URL="${BREAKOUT_URL:-http://10.99.0.1:8989}"
MESH_NET="${MESH_NET:-vlan}"
export MESH_NET                       # build.sh / mesh_ctl.sh inherit it
NETEM_DELAY="${NETEM_DELAY:-delay 200ms 50ms loss 10%}"
NETEM_DROP="${NETEM_DROP:-loss 25%}"

A=10.24.24.10; B=10.24.24.11; C=10.24.24.12; PORT=5000
EXPECTED=30                           # 3 nodes x 10; transfers conserve the total
TRAFFIC_PID=

# --- helpers ---------------------------------------------------------------

create_bridge() {
    if sudo podman network exists "$MESH_NET"; then
        local drv
        drv=$(sudo podman network inspect "$MESH_NET" --format '{{.Driver}}' 2>/dev/null)
        if [ "$drv" != "bridge" ]; then
            echo "ERROR: network '$MESH_NET' exists with driver '$drv'; single-host needs a bridge." >&2
            echo "       Remove it (sudo podman network rm $MESH_NET) or set MESH_NET to a new name." >&2
            exit 1
        fi
        echo "[*] reusing existing bridge network '$MESH_NET'"
    else
        echo "[*] creating bridge mesh network '$MESH_NET' (10.24.24.0/24)"
        sudo podman network create --subnet 10.24.24.0/24 --gateway 10.24.24.1 "$MESH_NET"
    fi
}

ensure_up() {
    if [ "$(sudo podman inspect -f '{{.State.Running}}' counter-a 2>/dev/null)" != "true" ]; then
        echo "[*] mesh not up; running 'up' first"
        cmd_up
    fi
}

# The mesh interface name inside a node's (shared) netns. Detected from the
# sidecar -- the counter image has no iproute2; the sidecar does. Detected by IP
# so it survives a CRIU restore that may rename the device.
mesh_iface() { # mesh_iface <node-letter>
    sudo podman exec "sidecar-$1" sh -c \
        "ip -o -4 addr show | grep -m1 'inet 10.24.24.' | awk '{print \$2}'" 2>/dev/null
}

netem_on() { # netem_on <netem-spec> -- apply to each node's mesh egress
    local spec="$1" n dev
    for n in a b c; do
        dev=$(mesh_iface "$n")
        if [ -n "$dev" ]; then
            sudo podman exec "sidecar-$n" tc qdisc replace dev "$dev" root netem $spec \
                && echo "    sidecar-$n ($dev): netem $spec"
        else
            echo "WARN: no mesh iface in sidecar-$n (skipping)" >&2
        fi
    done
}

netem_off() {
    local n dev
    for n in a b c; do
        dev=$(mesh_iface "$n")
        [ -n "$dev" ] && sudo podman exec "sidecar-$n" tc qdisc del dev "$dev" root 2>/dev/null \
            && echo "    sidecar-$n ($dev): netem removed"
    done
}

# Background ring traffic. The +1 ring conserves the total; serial calls only
# (counter.py binds a fixed client port, so parallel drivers would collide). A
# failed transfer to a node that is mid-restore is a no-op -- it moves nothing,
# so it cannot break conservation.
start_traffic() {
    ( while :; do
        ./mesh_ctl.sh transfer "$A" "$PORT" "$B" "$PORT" 1 >/dev/null 2>&1
        ./mesh_ctl.sh transfer "$B" "$PORT" "$C" "$PORT" 1 >/dev/null 2>&1
        ./mesh_ctl.sh transfer "$C" "$PORT" "$A" "$PORT" 1 >/dev/null 2>&1
        sleep 0.3
      done ) &
    TRAFFIC_PID=$!
    echo "[*] background ring traffic running (pid $TRAFFIC_PID)"
}

stop_traffic() {
    [ -n "$TRAFFIC_PID" ] || return 0
    kill "$TRAFFIC_PID" 2>/dev/null || true
    wait "$TRAFFIC_PID" 2>/dev/null || true
    TRAFFIC_PID=
    echo "[*] background traffic stopped"
}

wait_for_artifacts() { # wait_for_artifacts <id>
    local id="$1" n=0 i
    for i in $(seq 1 30); do
        n=$(curl -fsS --max-time 5 "$BREAKOUT_URL/snapshot/$id" 2>/dev/null \
            | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("nodes",[])))' \
            2>/dev/null || echo 0)
        if [ "$n" -ge 3 ]; then
            echo "[*] $n/3 node artifacts present for '$id'"
            return 0
        fi
        sleep 1
    done
    echo "ERROR: only $n/3 artifacts for '$id' after 30s" >&2
    return 1
}

report_inflight() { # report_inflight <id> -- informational, not a gate
    local id="$1" n f cap
    echo "[*] in-flight messages recorded at the cut (channel state):"
    for n in a b c; do
        f="/tmp/snapshot-$id-counter-$n.json"
        cap=$(sudo python3 -c \
            "import json; d=json.load(open('$f')); print(sum(len(p.get('channel',[])) for p in d.get('peers',{}).values()))" \
            2>/dev/null || echo "?")
        echo "      node $n: $cap"
    done
}

verify_total() { # verify_total <id>
    echo "[*] verifying conserved total == $EXPECTED"
    if ./mesh_ctl.sh sum "$A" "$PORT" "$B" "$PORT" "$C" "$PORT" "$EXPECTED" 8000 5; then
        echo "[PASS] total == $EXPECTED after snapshot+restore ($1)"
        return 0
    fi
    echo "[FAIL] total != $EXPECTED after snapshot+restore ($1)" >&2
    return 1
}

# Shared core for snapshot/delayed/dropped. Live traffic flows throughout; netem
# is applied to the CHECKPOINT window and/or the RESTORE window per the args
# (empty arg => no netem for that window). Restore-window netem is applied to the
# FRESH sidecars after run_restore -- CRIU recreates each node's netns, so any
# qdisc set before restore is wiped; dropping "during restore" means dropping the
# replay/resume traffic of the just-restored nodes.
run_cut() { # run_cut <id> <checkpoint-netem> <restore-netem>
    local id="$1" ckpt_netem="$2" rst_netem="$3"
    ensure_up
    echo "[*] resetting baseline (total=$EXPECTED)"
    ./mesh_ctl.sh bootstrap 10 || return 1

    start_traffic
    sleep 1

    # --- checkpoint / cut window ---
    if [ -n "$ckpt_netem" ]; then
        echo "[*] netem during checkpoint: $ckpt_netem"
        netem_on "$ckpt_netem"
    fi
    echo "[*] triggering global snapshot '$id' from node a"
    ./trigger_snapshot.sh a "$id"
    wait_for_artifacts "$id"; local arts=$?
    [ -n "$ckpt_netem" ] && netem_off
    if [ "$arts" -ne 0 ]; then
        stop_traffic
        echo "[FAIL] snapshot artifacts incomplete" >&2
        return 1
    fi
    report_inflight "$id"

    # --- restore / resume window ---
    echo "[*] restoring a b c from snapshot '$id'"
    ./run_restore.sh "$id" a b c
    if [ -n "$rst_netem" ]; then
        echo "[*] netem during restore/resume: $rst_netem"
        netem_on "$rst_netem"     # fresh sidecars are up now; drop the resume traffic
        sleep 3
        netem_off
    fi

    stop_traffic
    sleep 3                       # let RUDP deliver any last in-flight credits
    verify_total "$id"
}

# --- subcommands -----------------------------------------------------------

cmd_up() {
    create_bridge
    # build.sh builds the counter+sidecar images on its first call and sets up
    # the shared breakout net/anchor/receiver; the next two calls skip that via
    # build.sh's own idempotent guards. mesh_ctl.sh builds test-runner if needed.
    ./build.sh a A
    ./build.sh b B
    ./build.sh c C
    echo "[*] warming + verifying baseline (total=$EXPECTED)"
    if ./mesh_ctl.sh bootstrap 10; then
        echo "[OK] mesh up; total == $EXPECTED verified; ready to snapshot"
    else
        echo "[FAIL] bootstrap did not verify total == $EXPECTED" >&2
        return 1
    fi
}

cmd_down() {
    echo "[*] tearing down single-host mesh"
    sudo podman rm -f counter-a counter-b counter-c \
        sidecar-a sidecar-b sidecar-c \
        mesh-ctl sidecar-ctl breakout-anchor 2>/dev/null || true
    # Kill the receiver BEFORE removing the bridge: its IP_FREEBIND bind keeps
    # :8989 held otherwise, and the next 'up' can't health-check cleanly.
    sudo pkill -f 'breakout_receiver.py --host' 2>/dev/null || true
    sudo podman network rm breakout 2>/dev/null || true
    sudo podman network rm "$MESH_NET" 2>/dev/null || true
    sudo rm -f /tmp/snapshot-* /tmp/breakout-receiver.log 2>/dev/null || true
    echo "[*] teardown complete"
}

# --- dispatch --------------------------------------------------------------

case "${1:-}" in
    up)        cmd_up ;;
    snapshot)  shift; run_cut "${1:-snap1}"        ""             "" ;;
    delayed)   shift; run_cut "${1:-snap-delayed}" "$NETEM_DELAY" "" ;;
    dropped)   shift; run_cut "${1:-snap-dropped}" "$NETEM_DROP"  "$NETEM_DROP" ;;
    down)      cmd_down ;;
    *) echo "usage: $0 {up | snapshot <id> | delayed <id> | dropped <id> | down}" >&2; exit 1 ;;
esac
