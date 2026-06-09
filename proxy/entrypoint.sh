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

echo "[*] Configuring TPROXY routing rules for subnet: $MESH_SUBNET"

ip rule add fwmark 1 lookup 100
ip route add local 0.0.0.0/0 dev lo table 100
iptables -t mangle -A OUTPUT -p udp -d "$MESH_SUBNET" -m mark ! --mark 99 -j MARK --set-mark 1
iptables -t mangle -A PREROUTING -p udp -m mark --mark 1 -j TPROXY --on-port 9000 --tproxy-mark 1
echo "[*] TPROXY routing configured successfully."
exec python mesh_proxy.py
