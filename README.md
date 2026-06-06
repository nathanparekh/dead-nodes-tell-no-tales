
This is what I've decided instance names will be arbitrarily lol

- Node A: `172.31.34.109`
- Node B: `172.31.32.239`
- Node C: `172.31.47.64`

Run `./build.sh <container_name> <node_name>` to build and run a container on the specified node. Do each time counter is recompiled.

Right now, `run.sh` in `tests/` only runs `test_local_b.sh`, which should be run on node b (`172.31.32.239`) which tests pausing and restoring a container on the same node. I have more to add once I know what bash commands migrate the containers.

make sure to run `sudo ./run.sh`
