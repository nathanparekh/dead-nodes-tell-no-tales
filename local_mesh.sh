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
#   ./local_mesh.sh snapshot <id>    # trigger global cut, restore a/b/c, verify total=30
#   ./local_mesh.sh delayed  <id>    # same, but perturb the cut with netem (delay + loss)
#   ./local_mesh.sh down             # tear everything down (idempotent)
#
# Honors env MESH_NET (default "vlan") and NETEM (default "delay 200ms 50ms loss 10%").

set -u

cd "$(dirname "$0")" || exit 1

BREAKOUT_URL="${BREAKOUT_URL:-http://10.99.0.1:8989}"
MESH_NET="${MESH_NET:-vlan}"
export MESH_NET                       # build.sh / mesh_ctl.sh inherit it
NETEM="${NETEM:-delay 200ms 50ms loss 10%}"

A=10.24.24.10; B=10.24.24.11; C=10.24.24.12; PORT=5000
EXPECTED=30                           # 3 nodes x 10; transfers conserve the total

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
# sidecar -- the counter image has no iproute2; the sidecar does.
mesh_iface() { # mesh_iface <node-letter>
    sudo podman exec "sidecar-$1" sh -c \
        "ip -o -4 addr show | grep -m1 'inet 10.24.24.' | awk '{print \$2}'" 2>/dev/null
}

netem_on() {
    local n dev
    for n in a b c; do
        dev=$(mesh_iface "$n")
        if [ -n "$dev" ]; then
            sudo podman exec "sidecar-$n" tc qdisc replace dev "$dev" root netem $NETEM \
                && echo "[*] netem on sidecar-$n ($dev): $NETEM"
        else
            echo "WARN: could not find mesh iface in sidecar-$n (skipping)" >&2
        fi
    done
}

netem_off() {
    local n dev
    for n in a b c; do
        dev=$(mesh_iface "$n")
        [ -n "$dev" ] && sudo podman exec "sidecar-$n" tc qdisc del dev "$dev" root 2>/dev/null \
            && echo "[*] netem removed on sidecar-$n ($dev)"
    done
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

cmd_snapshot() { # cmd_snapshot <id>
    local id="$1"
    ensure_up
    echo "[*] triggering global snapshot '$id' from node a"
    ./trigger_snapshot.sh a "$id"
    wait_for_artifacts "$id" || return 1
    echo "[*] restoring a b c from snapshot '$id'"
    ./run_restore.sh "$id" a b c
    sleep 3
    verify_total "$id"
}

cmd_delayed() { # cmd_delayed <id>
    local id="$1"
    ensure_up
    echo "[*] resetting baseline before delayed run"
    ./mesh_ctl.sh bootstrap 10 || return 1

    echo "[*] applying netem to sidecar-a/b/c mesh egress"
    netem_on

    # Keep real credits moving across the cut so the snapshot has live channel
    # state to capture. Serial calls only -- counter.py binds a fixed client
    # port, so parallel drivers would collide. The +1 ring conserves the total.
    echo "[*] starting background ring traffic during the cut"
    ( for i in $(seq 1 15); do
        ./mesh_ctl.sh transfer "$A" "$PORT" "$B" "$PORT" 1 >/dev/null 2>&1
        ./mesh_ctl.sh transfer "$B" "$PORT" "$C" "$PORT" 1 >/dev/null 2>&1
        ./mesh_ctl.sh transfer "$C" "$PORT" "$A" "$PORT" 1 >/dev/null 2>&1
      done ) &
    local traffic_pid=$!

    sleep 1
    echo "[*] triggering global snapshot '$id' under netem ($NETEM)"
    ./trigger_snapshot.sh a "$id"
    wait_for_artifacts "$id"; local arts=$?

    echo "[*] stopping background traffic + removing netem"
    kill "$traffic_pid" 2>/dev/null || true
    wait "$traffic_pid" 2>/dev/null || true
    netem_off

    if [ "$arts" -ne 0 ]; then
        echo "[FAIL] snapshot artifacts incomplete under netem" >&2
        return 1
    fi
    report_inflight "$id"

    echo "[*] restoring a b c from snapshot '$id'"
    ./run_restore.sh "$id" a b c
    sleep 3
    # RUDP retransmit + a consistent global cut conserve the total despite the
    # delay/loss; a lost in-flight credit would settle below $EXPECTED.
    verify_total "$id"
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
    snapshot)  shift; cmd_snapshot "${1:-snap1}" ;;
    delayed)   shift; cmd_delayed "${1:-snap-delayed}" ;;
    down)      cmd_down ;;
    *) echo "usage: $0 {up | snapshot <id> | delayed <id> | down}" >&2; exit 1 ;;
esac
