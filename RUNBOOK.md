# RUNBOOK: whole-system Chandy-Lamport snapshot + restore (3 EC2 nodes)

End-to-end test of a global snapshot and per-node restore across three EC2
nodes (A, B, C). Each node runs ONE app `counter-<suffix>` + ONE sidecar
`sidecar-<suffix>` + its OWN host-local breakout receiver (binds the bridge
gateway `10.99.0.1:8989`). Snapshot artifacts live PER NODE on that node's
local `/tmp`; restore is therefore PER NODE — there is no shared store.

Mesh IP map (derived by `build.sh` from the suffix char, `a`→`.10`):

| Node | suffix | mesh IP      |
|------|--------|--------------|
| A    | a      | `10.24.24.10` |
| B    | b      | `10.24.24.11` |
| C    | c      | `10.24.24.12` |

The control container (used by `mesh_ctl.sh`) uses `10.24.24.200`.

All app traffic is UDP on port `5000`. The receiver base URL on EVERY node is
`http://10.99.0.1:8989` (each node's OWN bridge gateway — it is local, not
shared).

---

## 1. Prerequisites

- **VXLAN overlay (already set up):** the mesh subnet `10.24.24.0/24` is
  routable across all three nodes and UDP `9001` is open node-to-node. The
  proxy needs no changes — `sidecar-a` tunnels to `10.24.24.11:9001` and VXLAN
  carries it to node B with the mesh source IP preserved, so peer identity is
  consistent.
- **Podman mesh network (already set up):** every node already has an identical
  macvlan network named **`vlan`** (parent `br0`, the VXLAN-backed bridge),
  subnet `10.24.24.0/24`, gateway `10.24.24.1`. That is exactly `build.sh`'s
  default, so you do NOT create or rename anything — just confirm it exists:

  ```bash
  sudo podman network inspect vlan   # on each node; expect subnet 10.24.24.0/24
  ```

  `build.sh` and `mesh_ctl.sh` honor `MESH_NET` (default `vlan`); leave it unset
  to use `vlan`. Only export `MESH_NET` if your network is named differently.
- **Toolchain:** `podman` + `CRIU` + `sudo` available on each node.
- **Repo:** git-cloned on each node; run the scripts from the repo root.

---

## 2. Deploy (run ON EACH node)

Export the network name, then deploy that node's app + sidecar + local receiver:

```bash
# network defaults to "vlan" — no MESH_NET needed unless you renamed it

# on node A:
./build.sh a A

# on node B:
./build.sh b B

# on node C:
./build.sh c C
```

`build.sh <suffix> <NAME>` deploys onto `MESH_NET` (mesh IP from the suffix),
attaches the breakout bridge, and idempotently starts THIS node's local
breakout receiver (`--mesh-subnet 10.24.24.0/24`). After this, each node is
running its own `counter-<suffix>`, `sidecar-<suffix>`, and a receiver on
`10.99.0.1:8989`.

---

## 3. Drive the mesh (from ONE control node)

Pick any one node as the control node; `mesh_ctl.sh` brings up a control
container + sidecar at `10.24.24.200` on `MESH_NET` and runs `counter.py`
against the mesh. Reset all three to 10, WARM every directed pair, then verify
the total.

```bash
# reset every node to 10 (total = 30)
./mesh_ctl.sh reset 10.24.24.10 5000 10
./mesh_ctl.sh reset 10.24.24.11 5000 10
./mesh_ctl.sh reset 10.24.24.12 5000 10

# WARM every directed pair: A->B, B->C, C->A.
# This both primes lazy peer discovery (so every sidecar knows every peer)
# AND creates real in-flight / credit state for the cut to capture.
./mesh_ctl.sh transfer 10.24.24.10 5000 10.24.24.11 5000 1   # A -> B
./mesh_ctl.sh transfer 10.24.24.11 5000 10.24.24.12 5000 1   # B -> C
./mesh_ctl.sh transfer 10.24.24.12 5000 10.24.24.10 5000 1   # C -> A

# verify the conserved total is 30 (a ring of +1/-1 transfers nets to 0)
./mesh_ctl.sh sum 10.24.24.10 5000 10.24.24.11 5000 10.24.24.12 5000 30 5000 10
```

The `sum` verb args are `A_HOST A_PORT B_HOST B_PORT C_HOST C_PORT EXPECTED
TIMEOUT_MS STABLE_POLLS`; here it asserts the total settles at `30`.

---

## 4. Take a global snapshot (on the initiator node)

Trigger from the node you want to initiate the cut (here, node A). It floods
markers to every peer; each node records its channel state and writes its OWN
artifacts to its OWN local `/tmp`.

```bash
# on the initiator node (node A):
./trigger_snapshot.sh a snap1
```

`trigger_snapshot.sh <node> <snapshot_id>` POSTs the LOCAL receiver
`/snapshot_trigger`, which execs `__START_SNAPSHOT__` into `counter-a`'s netns;
node A then initiates and floods markers to its peers, who flood onward.

Inspect PER NODE (run on each node — each holds only its own piece):

```bash
curl -s http://10.99.0.1:8989/snapshot/snap1
ls -l /tmp/snapshot-snap1-*
```

You should see, on each node, that node's two artifacts:

- `/tmp/snapshot-snap1-counter-<node>.json`  — channel-state cut (recorded
  channel + send/recv seq coordinates)
- `/tmp/snapshot-snap1-counter-<node>.tar.zst` — that node's app CRIU image

---

## 5. Simulate failure + restore (PER NODE)

Optionally kill an app first to demonstrate the fault (on that node):

```bash
sudo podman rm -f counter-b sidecar-b    # simulate node B's app dying
```

Restore — run `run_restore.sh` ON EACH node with that node's OWN letter:

```bash
# on node A:
./run_restore.sh snap1 a

# on node B:
./run_restore.sh snap1 b

# on node C:
./run_restore.sh snap1 c
```

Per node, this drives the LOCAL receiver to: stop the old sidecar then app,
restore the app from its local CRIU image (`/tmp/snapshot-snap1-counter-<node>.tar.zst`),
and start a FRESH restore-mode sidecar that loads this node's artifact, sets
per-peer `send_seq`/`recv_seq`, replays the recorded channel once in seq order,
then resumes live traffic.

---

## 6. Verify

From the control node, the conserved total must still be `30` — proof the cut
and restore were globally consistent:

```bash
./mesh_ctl.sh sum 10.24.24.10 5000 10.24.24.11 5000 10.24.24.12 5000 30 5000 10
```

---

## 7. Gotchas

- **Warm ALL directed pairs before snapshotting.** Marker fan-out uses
  lazily-discovered peers. If you skip a pair (e.g. never send C->A), the
  sidecar that never learned a peer omits it, and the global cut SILENTLY drops
  that node. Always warm A->B, B->C, C->A (step 3) first.
- **Artifacts and restore are PER NODE.** Each node holds its own
  `*.json` + `*.tar.zst` on its own local `/tmp`; there is no shared store.
  `run_restore.sh snap1 <letter>` must be run on each node with its own letter,
  against that node's own local receiver.
- **The breakout receiver is local to each node.** `10.99.0.1` is each node's
  OWN bridge gateway; `http://10.99.0.1:8989` always means "this node's
  receiver." `build.sh` starts it per node.
- **Snapshot/restore semantics.** Sidecars are NEVER CRIU'd. The cut for a node
  = (its app CRIU image) + (its recorded channel state with send/recv seq
  coordinates). On restore the app is brought back from its image and a FRESH
  restore-mode sidecar replays the recorded channel and restores the seq
  coordinates, so no in-flight credits are lost or duplicated.
