#!/bin/bash
sudo podman run -d --rm --network vlan --name sender udp-tester --send --ip 10.24.24.24 --port 5005
sudo podman run -d --name sidecar-sender \
	  --network container:sender \
	    --cap-add NET_ADMIN \
	      rudp-sidecar
sudo podman logs -f sidecar-sender
#sudo podman logs -f sender
