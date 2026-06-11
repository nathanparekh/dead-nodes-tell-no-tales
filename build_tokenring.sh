#!/bin/bash
# deploy_node.sh (token ring)

if [ "$#" -lt 3 ]; then
    echo "Usage: $0 <container_suffix> <node_name> <has_token> <proxy-optional>"
    echo "Example: $0 b B 0 n"
    echo "Env knobs: HOLD_MS (default 500), LOSS_TIMEOUT_MS (default: loss recovery off)"
    echo "The M5/M6 demo requires LOSS_TIMEOUT_MS (e.g. 60000) on every node."
    exit 1
fi

PROXY=true
if [ "$4" = "n" ]; then
    PROXY=false
fi

BREAKOUT_NET=breakout
BREAKOUT_GW=10.99.0.1
BREAKOUT_URL="http://$BREAKOUT_GW:8989"

sudo podman build --network=host -t tokenring -f Containerfile.tokenring .

if [ "$PROXY" = true ]; then
  sudo podman build --network=host -t sidecar -f Containerfile.rudp .
fi

# Prepare names so we only remove the app and sidecar containers
SUFFIX=$1
NODE_NAME=${2^^}
HAS_TOKEN=$3
APP_NAME="tokenring-$SUFFIX"
SIDECAR_NAME="sidecar-$SUFFIX"

# Map out the subnet IP (e.g., b -> 10.24.24.11)
CHAR_LOWER=$(echo "${SUFFIX:0:1}" | tr '[:upper:]' '[:lower:]')
ASCII_VAL=$(printf "%d" "'$CHAR_LOWER")
IP_SUFFIX=$((ASCII_VAL - 97 + 10))
IP="10.24.24.$IP_SUFFIX"
MESH_SUBNET="10.24.24.0/24"

# Ring successor is fixed a -> b -> c -> a (e.g., b -> 10.24.24.12)
NEXT_IP_SUFFIX=$(( (ASCII_VAL - 97 + 1) % 3 + 10 ))
NEXT_IP="10.24.24.$NEXT_IP_SUFFIX"

# Remove only the app and sidecar containers if they exist
# sudo podman rm -fa

echo "=== Deploying Container $APP_NAME ==="

# The sidecar's snapshot handler calls the host's breakout receiver, and it
# shares the app container's network namespace — so the app container gets the
# breakout bridge attached when (and only when) it carries a sidecar. The host
# is unreachable by name from a macvlan child interface, which is exactly why
# the breakout bridge (and its fixed gateway 10.99.0.1) exists.
NETWORK_ARGS=(--network "vlan:ip=$IP")
if [ "$PROXY" = true ]; then
    if ! sudo podman network exists "$BREAKOUT_NET"; then
        echo "[*] Creating breakout network ($BREAKOUT_GW)"
        sudo podman network create --subnet 10.99.0.0/24 --gateway "$BREAKOUT_GW" "$BREAKOUT_NET"
    fi
    NETWORK_ARGS+=(--network "$BREAKOUT_NET")
    # Note: the sidecar POSTs pair-checkpoints to the host receiver; start it
    # with `sudo python3 proxy/breakout_receiver.py` (node_ctl.sh / the demo
    # harness do this — see harness/README.md).
fi

# 2. Launch the core application container onto the macvlan network
if [ "$HAS_TOKEN" = "1" ]; then
    echo "[!] HAS_TOKEN=1: deploy this node LAST. Its successor ($NEXT_IP) must already be"
    echo "[!] running, or the boot token (forwarded HOLD_MS after start) is lost forever."
fi
echo "[*] Starting App Container: $APP_NAME on IP $IP (successor $NEXT_IP)"
sudo podman run -d --replace \
  --name "$APP_NAME" \
  "${NETWORK_ARGS[@]}" \
  tokenring node "$NODE_NAME" 5000 "$NEXT_IP" 5000 "$HAS_TOKEN" "${HOLD_MS:-500}" ${LOSS_TIMEOUT_MS:+"$LOSS_TIMEOUT_MS"}

if [ "$PROXY" = true ]; then
    # 3. Launch the sidecar sharing the EXACT same network namespace
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

    sudo podman logs -f $SIDECAR_NAME
fi
