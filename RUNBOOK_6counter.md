# RUNBOOK: 6-container Counter snapshot-under-load test (3 EC2 nodes)

A global Chandy-Lamport snapshot taken while the mesh is under continuous load,
with **6 counters — 2 on each of the 3 physical nodes**. The control container
sends transfers continuously, both before and after the cut; the test passes if
the conserved total is unchanged afterwards.

This is the 6-container variant of `RUNBOOK.md`. It uses the same images,
networks, and breakout receiver — only the topology and the driver differ.
`counter.py` is unchanged. No SSH; restore is per-node and not driven here.

## Topology

`build.sh` derives the mesh IP from the suffix char (`a`→`.10`). We use six
suffixes `a`–`f`, paired 2-per-node:

| Physical node | counters                | mesh IPs              |
|---------------|-------------------------|-----------------------|
| A             | `counter-a`, `counter-d` | `10.24.24.10`, `10.24.24.13` |
| B             | `counter-b`, `counter-e` | `10.24.24.11`, `10.24.24.14` |
| C             | `counter-c`, `counter-f` | `10.24.24.12`, `10.24.24.15` |

The control container (`mesh-ctl`, started by `mesh_ctl.sh`) uses `10.24.24.200`
and is deliberately **not** a mesh member, so it is never recorded in the cut.
All app traffic is UDP on port `5000`. Each node has its OWN breakout receiver
at `http://10.99.0.1:8989`; snapshot artifacts live PER NODE on that node's
local `/tmp`.

## Prerequisites

Same as `RUNBOOK.md`: the VXLAN overlay `10.24.24.0/24` is routable across all
three nodes (UDP `9001` open node-to-node), the `vlan` macvlan network exists on
each node, and `podman` + `CRIU` + `sudo` are available. The repo is cloned on
each node; run scripts from the repo root.

> **Why all six members must be known everywhere.** The snapshot marker fan-out
> and the recording set are derived from `MESH_MEMBERS` (see `config.py` /
> `proxy/snapshot_handler.py`), not from lazily-discovered peers. If a sidecar
> only knew the default 3 members, the global cut would **silently drop** the
> other 3 nodes. `deploy6.sh` exports the full 6-member list and `build.sh`
> forwards it to every sidecar, so this is handled for you — just use
> `deploy6.sh` rather than calling `build.sh` by hand.

## 1. Deploy — run ON EACH node with that node's letter

Each node deploys only its own pair (no SSH). Run all three at once for speed:

```bash
# on node A:
./test/deploy6.sh A      # brings up counter-a + counter-d (+ sidecars)

# on node B:
./test/deploy6.sh B      # counter-b + counter-e

# on node C:
./test/deploy6.sh C      # counter-c + counter-f
```

`deploy6.sh` exports `MESH_MEMBERS` (all six IPs) and calls `build.sh` twice, so
each node ends up running its two `counter-<suffix>` + `sidecar-<suffix>` pairs,
its breakout-anchor, and its local breakout receiver on `10.99.0.1:8989`.

Confirm (on each node):

```bash
sudo podman ps --format '{{.Names}}' | sort      # expect this node's two counter-* + sidecar-*
```

## 2. Run the test — from ONE node (node A, the initiator)

```bash
# on node A:
./test/test_6counter.sh           # or: ./test/test_6counter.sh mysnapid
```

The driver, all through the control container (`mesh-ctl`):

1. Resets all six counters to `10` (total `60`) and warms the ring
   `a→b→c→d→e→f→a` so every sidecar has learned every peer.
2. Verifies the total settles at `60`.
3. Starts a **continuous** `+1` ring of transfers (each lap nets to zero, so the
   total stays `60`) and lets it flow for a few seconds — load BEFORE the cut.
4. Triggers a global snapshot (`trigger_snapshot.sh a <snap_id>`) **mid-flight**.
5. Keeps the load running a few seconds AFTER the cut, then stops it.
6. Re-verifies the total returns to `60`.

> The driver assumes it runs on physical node A (it initiates the snapshot
> locally, `INIT_NODE=a`). Run it on the node whose letter is `a`.

Expected tail:

```
PASS: total conserved at 60 across a global snapshot taken under live load.
```

`counter.py`'s `sum` verb only spans 3 nodes, so the driver sums the six via
`state` instead — it does not modify `counter.py`.

## 3. Inspect the snapshot (PER NODE)

Each node wrote only its own pieces to its own local `/tmp`:

```bash
# on each node:
curl -s http://10.99.0.1:8989/snapshot/<snap_id>
ls -l /tmp/snapshot-<snap_id>-counter-*        # this node's two .json + .tar.zst
```

You should see, across the three nodes, all six artifacts:
`counter-a/b/c/d/e/f`, each with a `.json` (channel-state cut) and a `.tar.zst`
(app CRIU image).

## 4. Optional: restore (PER NODE, not driven by the test)

Restore is per-node and independent of this test. On each node, restore that
node's own counters with their letters:

```bash
# on node A:
./run_restore.sh <snap_id> a d
# on node B:
./run_restore.sh <snap_id> b e
# on node C:
./run_restore.sh <snap_id> c f
```

Then re-verify conservation by re-running step 2's checks (or just
`./test/test_6counter.sh` again, which re-bootstraps).

## Gotchas

- **Always deploy with `deploy6.sh`, not bare `build.sh`.** The 6-member
  `MESH_MEMBERS` is what makes the global cut include all six nodes. A node
  deployed with plain `build.sh` (3-member default) gets silently dropped from
  the cut.
- **Artifacts and restore are PER NODE.** There is no shared store; `10.99.0.1`
  is each node's OWN bridge gateway.
- **Warm before snapshotting.** `test_6counter.sh` warms the full ring for you;
  if you drive the mesh by hand, warm every directed pair around the ring first
  so each sidecar has real in-flight state to capture.
- **Momentary sub-total during load is normal.** A transfer debits the sender
  immediately and credits the receiver asynchronously, so a mid-flight total can
  dip below `60` for a beat. The driver polls until the total settles, so this
  does not cause a false FAIL.
