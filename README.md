# dead-nodes-tell-no-tales

Three UDP "counter" nodes on a podman macvlan mesh (`10.24.24.0/24`), each with an
optional RUDP sidecar proxy. A host-side HTTP "breakout receiver" performs CRIU
checkpoint/restore on behalf of the containers. See `build.sh` / `run_test_suite.sh`.

Mesh node addresses (assigned by `build.sh` from the container suffix, `a`→`.10`):

- Node A: `10.24.24.10`
- Node B: `10.24.24.11`
- Node C: `10.24.24.12`
