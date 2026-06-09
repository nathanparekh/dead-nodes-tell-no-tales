#!/bin/bash
sudo podman rm -f $(sudo podman ps -aq) >/dev/null 2>&1
sudo podman rm -f $(sudo podman ps -aq) >/dev/null 2>&1
echo "Cleaned up existing containers."
sudo podman run -d --network vlan:ip=10.24.24.24 --name recv udp-counter --recv
echo "Started receiver container"

# sudo podman logs -f recv
sudo podman run -d --name sidecar-recv \
 	  --network container:recv \
 	    --cap-add NET_ADMIN \
 	      rudp-sidecar
echo "Started sidecar container"
#sudo podman logs -f sidecar-recv
#sudo podman logs -f recv

