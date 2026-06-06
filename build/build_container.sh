#!/bin/bash

CONTAINER_NAME=$1
NODE_NAME=${1^^}

echo "Building and running container $CONTAINER_NAME on node $NODE_NAME"

sudo podman run -d --replace --name counter-"$CONTAINER_NAME" --network host udp-counter node "$NODE_NAME" 9000 10