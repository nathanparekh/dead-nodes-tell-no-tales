#!/bin/bash

sudo podman build -t udp-counter -f Containerfile.app .
sudo podman build -t rudp-sidecar -f Containerfile.rudp .
