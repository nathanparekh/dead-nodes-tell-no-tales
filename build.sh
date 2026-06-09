#!/bin/bash
# deploy_node.sh

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <container_suffix> <node_name> <proxy-optional>"
    echo "Example: $0 b B n"
    exit 1
fi

PROXY=true
if [ "$3" = "n" ]; then
    PROXY=false
fi

sudo podman build --network=host -t counter -f Containerfile.counter .

if [ "$PROXY" = true ]; then
  sudo podman build --network=host -t sidecar -f Containerfile.rudp .
fi

# Prepare names so we only remove the app and sidecar containers
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

# Remove only the app and sidecar containers if they exist
# sudo podman rm -fa

echo "=== Deploying Container $APP_NAME ==="

# 2. Launch the core application container onto the macvlan network
echo "[*] Starting App Container: $APP_NAME on IP $IP"
sudo podman run -d --replace \
  --name "$APP_NAME" \
  --network vlan:ip=$IP \
  counter node "$NODE_NAME" 5000 10

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
      sidecar

    sudo podman logs -f $SIDECAR_NAME
fi
