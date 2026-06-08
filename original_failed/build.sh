#!/bin/bash

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <container_name> <node_name>"
    exit 1
fi

sudo podman build -t udp-counter -f Containerfile .

CONTAINER_NAME=$1
NODE_NAME=${2^^}

# assign ip based on container name
# e.g. counter-a -> 10.24.24.10
#      counter-b -> 10.24.24.11, etc.

CHAR_LOWER=$(echo "${CONTAINER_NAME:0:1}" | tr '[:upper:]' '[:lower:]')
ASCII_VAL=$(printf "%d" "'$CHAR_LOWER")
IP_SUFFIX=$((ASCII_VAL - 97 + 10))
IP="10.24.24.$IP_SUFFIX"

echo "Building and running container $CONTAINER_NAME on node $NODE_NAME with IP $IP"

sudo podman run -d --replace --name counter-"$CONTAINER_NAME" --network vlan:ip=$IP udp-counter node "$NODE_NAME" 9000 10