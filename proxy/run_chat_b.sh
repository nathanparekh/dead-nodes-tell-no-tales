udo podman rm -f $(sudo podman ps -aq) >/dev/null 2>&1
sudo podman run -d --rm --network vlan:ip=10.24.24.25 --name b udp-test Node-B 6000 10.24.24.24 5000
sudo podman run -d --name sidecar-b \
	--network container:b \
	--cap-add NET_ADMIN \
	rudp-sidecar
sudo podman logs -f b
