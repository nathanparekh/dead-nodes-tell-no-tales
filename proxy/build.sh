#!/bin/bash

sudo podman build --network=host -t udp-counter -f Containerfile.app .
sudo podman build --network=host -t udp-test -f Containerfile.test .
sudo podman build --network=host -t rudp-sidecar -f Containerfile.rudp .
