#!/bin/bash
# node_ctl.sh -- per-host root operations for the token ring demo harness.
#
# Run locally:        sudo bash harness/node_ctl.sh <cmd> <args...>
# Or piped over ssh:  <ssh-prefix> sudo bash -s -- <cmd> <args...>  < harness/node_ctl.sh
#
# It is self-contained: no other files needed on the remote host.
#
# Restore is artifact-based (main's snapshot/restore system): a snapshot writes,
# per node, a CRIU image and a channel-state cut keyed by snapshot_id, both under
# /tmp on the node's own host:
#   /tmp/snapshot-<sid>-tokenring-<suffix>.tar.zst   app CRIU image
#   /tmp/snapshot-<sid>-tokenring-<suffix>.json      channel-state cut
# A restore CRIU-restores the app, then starts a FRESH restore-mode sidecar (via
# the receiver's /run_sidecar, RESTORE_SNAPSHOT_ID=<sid>) which loads this node's
# artifact and replays the recorded channel before serving live traffic. There is
# no on-disk channel dump and no `latest` symlink -- restore is driven entirely by
# snapshot_id.
set -u

BREAKOUT_NET=breakout
BREAKOUT_GW=10.99.0.1
BREAKOUT_URL="http://$BREAKOUT_GW:8989"
MESH_SUBNET=10.24.24.0/24

usage() {
    cat <<'EOF'
Usage: node_ctl.sh <cmd> [args...]   (run as root; suffix is a|b|c)
  receiver-up                             start proxy/breakout_receiver.py on 10.99.0.1:8989 (idempotent)
  receiver-health                         exit 0 iff the breakout receiver answers /health
  netem-on <suffix> <dst_ip> <delay_ms>   delay packets to dst_ip inside sidecar-<suffix>
  netem-off <suffix>                      remove the netem qdisc
  has-snapshot <suffix> <sid>             exit 0 iff this node's CRIU image + artifact json exist for <sid>
  kill <suffix>                           remove app + sidecar containers
  restore <suffix> <sid>                  CRIU-restore the app, then start a restore-mode sidecar
                                          (RESTORE_SNAPSHOT_ID=<sid>) that replays the recorded channel
  restore-criu-only <suffix> <sid>        CRIU-restore the app, then start a PLAIN live sidecar (no
                                          RESTORE_SNAPSHOT_ID) -- the control: memory only, NO replay
  trigger-snapshot <suffix> <sid>         start a Chandy-Lamport snapshot keyed by <sid> from this node
                                          (drives the receiver's /snapshot_trigger)
  ps                                      list tokenring-*/sidecar-* containers
EOF
    exit 1
}

# Find proxy/breakout_receiver.py relative to this script if it sits in a repo
# checkout; otherwise fall back to a bare name (caller must run from the repo).
RECEIVER_PY="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)/proxy/breakout_receiver.py"

receiver_up() {
    if ! podman network exists "$BREAKOUT_NET"; then
        echo "[*] creating breakout network ($BREAKOUT_GW)" >&2
        podman network create --subnet 10.99.0.0/24 --gateway "$BREAKOUT_GW" "$BREAKOUT_NET"
    fi
    # Probe the port rather than pgrep: a filename substring match also hits
    # editors and sudo's own wrapper, wrongly suppressing startup.
    if timeout 2 bash -c "exec 3<>/dev/tcp/$BREAKOUT_GW/8989" 2>/dev/null; then
        echo "[*] breakout receiver already up on $BREAKOUT_URL" >&2
        return 0
    fi
    [ -f "$RECEIVER_PY" ] || { echo "missing $RECEIVER_PY (run from a repo checkout)" >&2; return 1; }
    echo "[*] starting breakout receiver on $BREAKOUT_URL" >&2
    nohup python3 "$RECEIVER_PY" --host "$BREAKOUT_GW" --port 8989 \
        --mesh-subnet "$MESH_SUBNET" \
        >/var/log/breakout_receiver.log 2>&1 &
    sleep 1
}

receiver_health() {
    curl -sf "http://$BREAKOUT_GW:8989/health" >/dev/null
}

# breakout <endpoint> <json-body> -- POST to the local breakout receiver.
breakout() {
    curl -fsS --max-time 150 -X POST -H "Content-Type: application/json" \
        -d "$2" "$BREAKOUT_URL/$1"
}

# sidecar_up <suffix> -- start a PLAIN live sidecar in the app's netns (same run
# line as build_tokenring.sh, minus the blocking `podman logs -f`, and with NO
# RESTORE_SNAPSHOT_ID so it does NOT replay any recorded channel). Used only for
# the CRIU-only control, right after a restore: a live app's netns still holds
# the old sidecar's TPROXY rules, so a replacement is only safe post-restore.
sidecar_up() {
    podman rm -f "sidecar-$1"
    podman run -d \
      --name "sidecar-$1" \
      --network "container:tokenring-$1" \
      --cap-add NET_ADMIN \
      --sysctl net.ipv4.ip_nonlocal_bind=1 \
      -e MESH_SUBNET="$MESH_SUBNET" \
      -e BREAKOUT_URL="$BREAKOUT_URL" \
      -e CHECKPOINT_TARGET="tokenring-$1" \
      sidecar
}

cmd=${1:-}

case "$cmd" in
  receiver-up)
    receiver_up
    ;;

  receiver-health)
    receiver_health
    ;;

  netem-on)
    sfx=$2; dst_ip=$3; delay_ms=$4
    podman exec "sidecar-$sfx" tc qdisc add dev eth0 root handle 1: prio
    podman exec "sidecar-$sfx" tc qdisc add dev eth0 parent 1:3 handle 30: netem delay "${delay_ms}ms"
    podman exec "sidecar-$sfx" tc filter add dev eth0 protocol ip parent 1: prio 1 \
        u32 match ip dst "$dst_ip/32" flowid 1:3
    ;;

  netem-off)
    sfx=$2
    podman exec "sidecar-$sfx" tc qdisc del dev eth0 root 2>/dev/null || true
    ;;

  has-snapshot)
    # Artifact layout: the app's snapshot handler exports the CRIU image and the
    # channel-state cut to /tmp on THIS host, keyed by snapshot_id and the app
    # container id (tokenring-<suffix> = CHECKPOINT_TARGET). Both must exist.
    sfx=$2; sid=$3
    test -f "/tmp/snapshot-$sid-tokenring-$sfx.tar.zst" \
      && test -f "/tmp/snapshot-$sid-tokenring-$sfx.json"
    ;;

  kill)
    sfx=$2
    podman rm -f "tokenring-$sfx" "sidecar-$sfx"
    ;;

  restore)
    # CRIU-restore the app from its image, then start a FRESH restore-mode
    # sidecar via the receiver's /run_sidecar. RESTORE_SNAPSHOT_ID makes that
    # sidecar load this node's artifact and replay the recorded channel into the
    # restored app before serving live traffic. No on-disk channel dump is read.
    sfx=$2; sid=$3
    podman rm -f "tokenring-$sfx"
    podman container restore --tcp-established --import "/tmp/snapshot-$sid-tokenring-$sfx.tar.zst"
    breakout run_sidecar "{\"node\": \"$sfx\", \"snapshot_id\": \"$sid\"}"
    ;;

  restore-criu-only)
    # The control: CRIU-restore the app's memory, then bring up a PLAIN sidecar
    # that does NOT replay the recorded channel. The in-flight token captured as
    # channel state is therefore lost, so the ring violates (duplicate epoch).
    sfx=$2; sid=$3
    podman rm -f "tokenring-$sfx"
    podman container restore --tcp-established --import "/tmp/snapshot-$sid-tokenring-$sfx.tar.zst"
    sidecar_up "$sfx"
    ;;

  trigger-snapshot)
    # Drive the receiver's /snapshot_trigger: it execs __START_SNAPSHOT__:<sid>
    # into tokenring-<suffix>'s netns, which floods markers to its peers; every
    # node then records its OWN piece of the global cut and exports its artifact.
    sfx=$2; sid=$3
    breakout snapshot_trigger "{\"node\": \"$sfx\", \"snapshot_id\": \"$sid\"}"
    ;;

  ps)
    podman ps -a --filter name=tokenring- --filter name=sidecar-
    ;;

  *)
    usage
    ;;
esac
