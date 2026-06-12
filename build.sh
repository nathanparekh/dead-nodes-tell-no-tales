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

BREAKOUT_NET=breakout
BREAKOUT_GW=10.99.0.1
BREAKOUT_PORT=8989
BREAKOUT_URL="http://$BREAKOUT_GW:$BREAKOUT_PORT"
# The app attaches to a podman network on the VXLAN overlay; the operator
# pre-creates it and passes its NAME via MESH_NET. Default stays "vlan".
MESH_NET="${MESH_NET:-vlan}"

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
# Deterministic, locally-administered MAC derived from the mesh IP so a redeploy
# REUSES the same MAC instead of getting a fresh one -- otherwise peers keep
# sending to the stale MAC until the node re-announces itself (the stale-ARP
# black hole that drops all traffic to a just-redeployed node). 0a:18:18 ==
# 10.24.24; last octet == IP_SUFFIX (e.g. b -> 02:00:0a:18:18:0b).
MESH_MAC=$(printf '02:00:0a:18:18:%02x' "$IP_SUFFIX")

# Remove only the app and sidecar containers if they exist
# sudo podman rm -fa

echo "=== Deploying Container $APP_NAME ==="

# The sidecar's snapshot handler calls the host's breakout receiver, and it
# shares the app container's network namespace — so the app container gets
# the breakout bridge attached when (and only when) it carries a sidecar.
NETWORK_ARGS=(--network "$MESH_NET:ip=$IP,mac=$MESH_MAC")
if [ "$PROXY" = true ]; then
    if ! sudo podman network exists "$BREAKOUT_NET"; then
        echo "[*] Creating breakout network ($BREAKOUT_GW)"
        sudo podman network create --subnet 10.99.0.0/24 --gateway "$BREAKOUT_GW" "$BREAKOUT_NET"
    fi
    NETWORK_ARGS+=(--network "$BREAKOUT_NET")

    # Keep a tiny always-on container on the breakout network so its bridge --
    # and the 10.99.0.1 gateway the receiver binds -- stays up even when the app
    # containers are stopped for a restore. Without it, stopping the apps drops
    # the bridge and the host (run_restore.sh) can no longer reach the receiver
    # (which still "listens" via IP_FREEBIND on an address nothing can route to).
    if [ "$(sudo podman inspect -f '{{.State.Running}}' breakout-anchor 2>/dev/null)" != "true" ]; then
        echo "[*] Starting breakout-anchor (keeps the breakout bridge up)"
        sudo podman run -d --replace --name breakout-anchor \
            --network "$BREAKOUT_NET" --entrypoint sleep sidecar infinity
    fi

    # Ensure THIS node's local breakout receiver is running on the host (root
    # for CRIU). Probe the port rather than pgrep -- a substring match on the
    # filename also hits editors and sudo's own wrapper, wrongly suppressing
    # startup.
    if ! timeout 2 bash -c "exec 3<>/dev/tcp/$BREAKOUT_GW/$BREAKOUT_PORT" 2>/dev/null; then
        echo "Starting breakout receiver on $BREAKOUT_URL..."
        # Detach with setsid + redirect (stdin from /dev/null) so the receiver
        # survives this deploy shell and the SSH session closing -- it is a
        # long-lived per-node daemon, not a child of the deploy. Logs to /tmp.
        sudo setsid python3 proxy/breakout_receiver.py --host "$BREAKOUT_GW" --port "$BREAKOUT_PORT" --mesh-subnet "$MESH_SUBNET" </dev/null >/tmp/breakout-receiver.log 2>&1 &
        sleep 1
    fi
fi

# 2. Launch the core application container onto the macvlan network
echo "[*] Starting App Container: $APP_NAME on IP $IP"
# Remove any existing sidecar FIRST: it joins the app's netns, so podman refuses
# to --replace the app while the sidecar depends on it -- the run then errors and
# silently leaves the OLD app container (with its stale MAC/state) running instead
# of redeploying. That is why an earlier "rebuild" didn't actually take effect.
if [ "$PROXY" = true ]; then
    sudo podman rm -f "$SIDECAR_NAME" 2>/dev/null || true
fi
sudo podman run -d --replace \
  --name "$APP_NAME" \
  "${NETWORK_ARGS[@]}" \
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
      -e BREAKOUT_URL="$BREAKOUT_URL" \
      -e CHECKPOINT_TARGET="$APP_NAME" \
      sidecar
fi

# Per-node deploy must not block; return after deploying.
echo "deployed $APP_NAME+$SIDECAR_NAME; receiver on $BREAKOUT_URL"
