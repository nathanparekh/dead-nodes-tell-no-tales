#!/bin/bash
sudo podman rm -fa
sudo podman run -d --rm --network vlan:ip=10.24.24.24 --name a udp-test Node-A 5000 10.24.24.25 6000
sudo podman run -d --name sidecar-a \
	--network container:a \
	--cap-add NET_ADMIN \
	rudp-sidecar
sudo podman logs -f a
