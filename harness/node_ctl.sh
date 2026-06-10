#!/bin/bash
# node_ctl.sh -- per-host root operations for the token ring demo harness.
#
# Run locally:        sudo bash harness/node_ctl.sh <cmd> <args...>
# Or piped over ssh:  <ssh-prefix> sudo bash -s -- <cmd> <args...>  < harness/node_ctl.sh
#
# It is self-contained: no other files needed on the remote host.
set -u

SNAP_DIR=${SNAP_DIR:-/var/lib/tokenring-demo}

usage() {
    cat <<'EOF'
Usage: node_ctl.sh <cmd> [args...]   (run as root; suffix is a|b|c)
  netem-on <suffix> <dst_ip> <delay_ms>   delay packets to dst_ip inside sidecar-<suffix>
  netem-off <suffix>                      remove the netem qdisc
  latest-snapshot                         newest snapshot id under SNAP_DIR (or empty)
  has-checkpoint <suffix> <sid>           exit 0 iff the checkpoint tarball exists
  fetch-channels <suffix> <sid>           print channel-state JSON from the sidecar ("{}" if missing)
  kill <suffix>                           remove app + sidecar containers
  restore <suffix> <sid>                  restore app from checkpoint, then restart sidecar
  sidecar-up <suffix>                     start the sidecar in the app's netns (only valid right
                                          after restore: a live app's netns still holds the old
                                          sidecar's TPROXY rules, so a replacement exits at boot)
  trigger-snapshot <suffix> <peer_ip>     ask the app to start a Chandy-Lamport snapshot
  ps                                      list tokenring-*/sidecar-* containers
EOF
    exit 1
}

# Same run line as build_tokenring.sh, minus the blocking "podman logs -f".
sidecar_up() {
    podman rm -f "sidecar-$1"
    podman run -d \
      --name "sidecar-$1" \
      --network "container:tokenring-$1" \
      --cap-add NET_ADMIN \
      --sysctl net.ipv4.ip_nonlocal_bind=1 \
      -e MESH_SUBNET=10.24.24.0/24 \
      sidecar
}

cmd=${1:-}

case "$cmd" in
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

  latest-snapshot)
    ls -t "$SNAP_DIR" 2>/dev/null | head -n 1
    ;;

  has-checkpoint)
    sfx=$2; sid=$3
    test -f "$SNAP_DIR/$sid/tokenring-$sfx.tar.zst"
    ;;

  fetch-channels)
    sfx=$2; sid=$3
    podman exec "sidecar-$sfx" cat "/tmp/channel_states_$sid.json" 2>/dev/null || echo "{}"
    ;;

  kill)
    sfx=$2
    podman rm -f "tokenring-$sfx" "sidecar-$sfx"
    ;;

  restore)
    sfx=$2; sid=$3
    podman rm -f "tokenring-$sfx"
    podman container restore --tcp-established --import "$SNAP_DIR/$sid/tokenring-$sfx.tar.zst"
    sidecar_up "$sfx"
    ;;

  sidecar-up)
    sidecar_up "$2"
    ;;

  trigger-snapshot)
    sfx=$2; peer_ip=$3
    podman exec "tokenring-$sfx" ./tokenring.py snapshot "$peer_ip" 5000
    ;;

  ps)
    podman ps -a --filter name=tokenring- --filter name=sidecar-
    ;;

  *)
    usage
    ;;
esac
