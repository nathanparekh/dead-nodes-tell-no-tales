#!/bin/bash
# deploy_node.sh
set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <container_suffix> <node_name>"
    echo "Example: $0 b B"
    exit 1
fi

sudo podman build --network=host -t udp-counter -f Containerfile .

SUFFIX=$1
NODE_NAME=${2^^}
APP_NAME="counter-$SUFFIX"
SIDECAR_NAME="sidecar-$SUFFIX"

# Map out the subnet IP (e.g., b -> 10.24.24.11)
CHAR_LOWER=$(echo "${SUFFIX:0:1}" | tr '[:upper:]' '[:lower:]')
ASCII_VAL=$(printf "%d" "'$CHAR_LOWER")
IP_SUFFIX=$((ASCII_VAL - 97 + 10))
IP="10.24.24.$IP_SUFFIX"
MESH_SUBNET="10.24.24.0/24"

echo "=== Deploying Container $APP_NAME ==="

sudo podman rm -f "$APP_NAME"
sudo podman rm -f "$SIDECAR_NAME"

# 2. Launch the core application container onto the macvlan network
echo "[*] Starting App Container: $APP_NAME on IP $IP"
sudo podman run -d --replace \
  --name "$APP_NAME" \
  --network vlan:ip=$IP \
  udp-counter node "$NODE_NAME" 9000 10

# 3. Launch the sidecar sharing the EXACT same network namespace
# It requires NET_ADMIN to implement the TPROXY rules inside that namespace
echo "[*] Attaching Sidecar Proxy: $SIDECAR_NAME"
sudo podman run -d --replace \
  --name "$SIDECAR_NAME" \
  --network "container:$APP_NAME" \
  --cap-add NET_ADMIN \
  -e MESH_SUBNET="$MESH_SUBNET" \
  rudp-sidecar