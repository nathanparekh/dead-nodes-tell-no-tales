#!/bin/sh
set -e

if [ -z "$MESH_SUBNET" ]; then
	DETECTED_SUBNET=$(ip route | grep -v default | awk '{print $1}' | head -n 1)
	if [ -z "$DETECTED_SUBNET" ]; then
		echo "[!] ERROR: Could not auto-detect subnet. Please provide MESH_SUBNET env var."
		exit 1
	fi
	export MESH_SUBNET=$DETECTED_SUBNET
fi

# Pin a deterministic MAC (02:00:0a:18:18:<last-octet-of-mesh-IP>) on the mesh
# interface. podman does not reliably honor --network mac= for macvlan, so it
# hands out a RANDOM MAC that changes on every (re)deploy and CRIU restore --
# which leaves peers' ARP caches stale and silently black-holes traffic to us.
# Doing it here, in the shared netns with NET_ADMIN, is podman-version-proof and
# runs on restore too (same entrypoint), so our MAC is stable across both.
MESH_IFACE=$(ip route | awk -v n="$MESH_SUBNET" '$1==n {print $3; exit}')
if [ -n "$MESH_IFACE" ]; then
	MESH_IP=$(ip -4 -o addr show "$MESH_IFACE" | awk '{print $4}' | cut -d/ -f1 | head -n 1)
	LAST=${MESH_IP##*.}
	if [ -n "$LAST" ]; then
		MESH_MAC=$(printf '02:00:0a:18:18:%02x' "$LAST")
		if ! ip link set dev "$MESH_IFACE" address "$MESH_MAC" 2>/dev/null; then
			ip link set dev "$MESH_IFACE" down 2>/dev/null || true
			ip link set dev "$MESH_IFACE" address "$MESH_MAC" 2>/dev/null || true
			ip link set dev "$MESH_IFACE" up 2>/dev/null || true
		fi
		echo "[*] Pinned deterministic mesh MAC $MESH_MAC on $MESH_IFACE ($MESH_IP)"
	fi
fi

echo "[*] Configuring TPROXY routing rules for subnet: $MESH_SUBNET"

ip rule add fwmark 1 lookup 100
ip route add local 0.0.0.0/0 dev lo table 100
iptables -t mangle -A OUTPUT -p udp -d "$MESH_SUBNET" -m mark ! --mark 99 -j MARK --set-mark 1
iptables -t mangle -A PREROUTING -p udp -m mark --mark 1 -j TPROXY --on-port 9000 --tproxy-mark 1
echo "[*] TPROXY routing configured successfully."
exec python mesh_proxy.py
