#!/bin/bash
# build_workqueue.sh (work queue deploy, per node)
#
# Fixed topology (matches the M6 harness, test/test_workqueue_snapshot.sh):
#   a = coordinator (10.24.24.10)
#   b = worker      (10.24.24.11)
#   c = worker      (10.24.24.12)
#   d = client      (10.24.24.13)  -- mesh-attached exec target, no app loop

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <container_suffix> <coordinator|worker|client> <proxy-optional>"
    echo "Example: $0 b worker"
    echo "         $0 b worker n    # no sidecar (never use 'n' for the client: its sidecar"
    echo "                          # must intercept __START_SNAPSHOT__ to initiate the snapshot)"
    exit 1
fi

SUFFIX=$1
ROLE=$2

case "$ROLE" in
    coordinator|worker|client) ;;
    *)
        echo "Unknown role: $ROLE (expected coordinator|worker|client)"
        exit 1
        ;;
esac

PROXY=true
if [ "$3" = "n" ]; then
    PROXY=false
fi

# Breakout bridge: the sidecar's snapshot handler POSTs to the host-side
# breakout receiver (proxy/breakout_receiver.py) at this gateway. The apps run
# on the `vlan` macvlan, which cannot route back to the host through the usual
# container-to-host gateway — hence the dedicated bridge. Mirrors build.sh.
BREAKOUT_NET=breakout
BREAKOUT_GW=10.99.0.1
BREAKOUT_URL="http://$BREAKOUT_GW:8989"

sudo podman build --network=host -t workqueue -f Containerfile.workqueue .

if [ "$PROXY" = true ]; then
  sudo podman build --network=host -t sidecar -f Containerfile.rudp .
fi

# Prepare names so we only touch the app and sidecar containers
NODE_NAME=${SUFFIX^^}
APP_NAME="workqueue-$SUFFIX"
SIDECAR_NAME="sidecar-$SUFFIX"

# Map out the subnet IP (e.g., b -> 10.24.24.11)
CHAR_LOWER=$(echo "${SUFFIX:0:1}" | tr '[:upper:]' '[:lower:]')
ASCII_VAL=$(printf "%d" "'$CHAR_LOWER")
IP_SUFFIX=$((ASCII_VAL - 97 + 10))
IP="10.24.24.$IP_SUFFIX"
MESH_SUBNET="10.24.24.0/24"

# Fixed defaults for the standard topology (a=coordinator, b/c=workers)
COORD_IP="10.24.24.10"
W1_IP="10.24.24.11"
W2_IP="10.24.24.12"
APP_PORT=5000

echo "=== Deploying Container $APP_NAME ($ROLE) ==="

# The sidecar's snapshot handler reaches the host breakout receiver through the
# breakout bridge, and it shares the app container's network namespace — so the
# app container gets the breakout bridge attached when (and only when) it
# carries a sidecar. Mirrors build.sh.
NETWORK_ARGS=(--network "vlan:ip=$IP")
if [ "$PROXY" = true ]; then
    if ! sudo podman network exists "$BREAKOUT_NET"; then
        echo "[*] Creating breakout network ($BREAKOUT_GW)"
        sudo podman network create --subnet 10.99.0.0/24 --gateway "$BREAKOUT_GW" "$BREAKOUT_NET"
    fi
    NETWORK_ARGS+=(--network "$BREAKOUT_NET")
fi

# Launch the core application container onto the macvlan network
echo "[*] Starting App Container: $APP_NAME on IP $IP"
case "$ROLE" in
    coordinator)
        sudo podman run -d --replace \
          --name "$APP_NAME" \
          "${NETWORK_ARGS[@]}" \
          workqueue coordinator "$NODE_NAME" $APP_PORT $W1_IP $APP_PORT $W2_IP $APP_PORT
        ;;
    worker)
        sudo podman run -d --replace \
          --name "$APP_NAME" \
          "${NETWORK_ARGS[@]}" \
          workqueue worker "$NODE_NAME" $APP_PORT "${PROC_DELAY_MS:-100}" $COORD_IP $APP_PORT
        ;;
    client)
        # The client is only a mesh-attached exec target: the harness drives
        # submit/status/verify via `podman exec`. The image is python:alpine,
        # so /bin/sleep exists; override the workqueue entrypoint.
        sudo podman run -d --replace \
          --name "$APP_NAME" \
          "${NETWORK_ARGS[@]}" \
          --entrypoint "" \
          workqueue sleep infinity
        ;;
esac

if [ "$PROXY" = true ]; then
    # Launch the sidecar sharing the EXACT same network namespace
    # It requires NET_ADMIN to implement the TPROXY rules inside that namespace
    echo "[*] Attaching Sidecar Proxy: $SIDECAR_NAME"
    sudo podman run -d --replace \
      --name "$SIDECAR_NAME" \
      --network "container:$APP_NAME" \
      --cap-add NET_ADMIN \
      --sysctl net.ipv4.ip_nonlocal_bind=1 \
      -e MESH_SUBNET="$MESH_SUBNET" \
      -e BREAKOUT_URL="$BREAKOUT_URL" \
      sidecar
fi

# Unlike the sibling deploy scripts, do NOT tail logs here: the M6 harness
# (test/test_workqueue_snapshot.sh) drives this script and must not block.
echo "[*] Deployed. Follow logs with: sudo podman logs -f $APP_NAME"
if [ "$PROXY" = true ]; then
    echo "[*]                       or: sudo podman logs -f $SIDECAR_NAME"
fi
