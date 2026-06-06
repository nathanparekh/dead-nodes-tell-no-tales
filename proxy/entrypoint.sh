#!/bin/bash
set -e

if [ -z "$MESH_SUBNET" ]; then
	echo "[*] MESH_SUBNET not provided. Attempting to auto-detect..."

	DETECTED_SUBNET=$(ip route | grep -v default | awk '{print $1}' | head -n 1)

	if [ -z "$DETECTED_SUBNET" ]; then
		echo "[!] ERROR: Could not auto-detect subnet. Please provide MESH_SUBNET env var."
		exit 1
	fi

	export MESH_SUBNET=$DETECTED_SUBNET
fi

echo "[*] Configuring transparent proxy iptables rules for subnet: $MESH_SUBNET"

iptables -t nat -A OUTPUT -p udp --dport 53 -j RETURN

iptables -t nat -A OUTPUT -p udp -m mark --mark 99 -j RETURN

iptables -t nat -A OUTPUT -p udp -d "$MESH_SUBNET" -j REDIRECT --to-ports 9000

echo "[*] iptables configured successfully."

exec python mesh_proxy.py
