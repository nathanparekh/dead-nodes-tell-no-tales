#!/bin/bash
sudo podman rm -f $(sudo podman ps -aq) >/dev/null 2>&1
sudo podman rm -f $(sudo podman ps -aq) >/dev/null 2>&1
sudo podman run -d --rm --network vlan:ip=10.24.24.24 --name recv udp-tester --recv
sudo podman run -d --name sidecar-recv \
 	  --network container:recv \
 	    --cap-add NET_ADMIN \
 	      rudp-sidecar
#sudo podman logs -f sidecar-recv
#sudo podman logs -f recv

