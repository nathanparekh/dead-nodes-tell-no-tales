# RUNBOOK: 6-container Counter snapshot-under-load test (2 EC2 nodes)

A global Chandy-Lamport snapshot taken while the mesh is under continuous load,
with **6 counters — 3 on each of the 2 physical nodes**. The control container
sends transfers continuously, both before and after the cut; the test passes if
the conserved total is unchanged afterwards.

This is the 6-container variant of `RUNBOOK.md`. It uses the same images,
networks, and breakout receiver — only the topology and the driver differ.
`counter.py` is unchanged. No SSH; restore is per-node and not driven here.

## Topology

`build.sh` derives the mesh IP from the suffix char (`a`→`.10`). We use six
suffixes `a`–`f`, 3-per-node across 2 nodes:

| Physical node | counters                              | mesh IPs                                |
|---------------|---------------------------------------|-----------------------------------------|
| A             | `counter-a`, `counter-b`, `counter-c` | `10.24.24.10`, `10.24.24.11`, `10.24.24.12` |
| B             | `counter-d`, `counter-e`, `counter-f` | `10.24.24.13`, `10.24.24.14`, `10.24.24.15` |

The control container (`mesh-ctl`, started by `mesh_ctl.sh`) uses `10.24.24.200`
and is deliberately **not** a mesh member, so it is never recorded in the cut.
All app traffic is UDP on port `5000`. Each node has its OWN breakout receiver
at `http://10.99.0.1:8989`; snapshot artifacts live PER NODE on that node's
local `/tmp`.

## Prerequisites

Same as `RUNBOOK.md`: the VXLAN overlay `10.24.24.0/24` is routable across the
nodes (UDP `9001` open node-to-node), the `vlan` macvlan network exists on each
node, and `podman` + `CRIU` + `sudo` are available. The repo is cloned on each
node; run scripts from the repo root. (This test uses 2 of the cluster's nodes;
a third node, if present, is simply unused here.)

> **Why all six members must be known everywhere.** The snapshot marker fan-out
> and the recording set are derived from `MESH_MEMBERS` (see `config.py` /
> `proxy/snapshot_handler.py`), not from lazily-discovered peers. If a sidecar
> only knew the default 3 members, the global cut would **silently drop** the
> other 3 nodes. `deploy6.sh` exports the full 6-member list and `build.sh`
> forwards it to every sidecar, so this is handled for you — just use
> `deploy6.sh` rather than calling `build.sh` by hand.

## 1. Deploy — run ON EACH node with that node's letter

Each node deploys only its own three (no SSH). Run both at once for speed:

```bash
# on node A:
./test/deploy6.sh A      # brings up counter-a + counter-b + counter-c (+ sidecars)

# on node B:
./test/deploy6.sh B      # counter-d + counter-e + counter-f
```

`deploy6.sh` exports `MESH_MEMBERS` (all six IPs) and calls `build.sh` three
times, so each node ends up running its three `counter-<suffix>` +
`sidecar-<suffix>` pairs, its breakout-anchor, and its local breakout receiver
on `10.99.0.1:8989`.

Confirm (on each node):

```bash
sudo podman ps --format '{{.Names}}' | sort      # expect this node's three counter-* + sidecar-*
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
3. Starts a **multithreaded** load generator inside the control container —
   `LOAD_THREADS` threads (default 4) firing ring transfers concurrently at a
   moderate, sustainable rate (~80/s, throttled by `LOAD_SLEEP`), so node→node
   CREDIT messages are genuinely **in transit on the channels** while the cut is
   taken. Each transfer nets to zero, so the total stays `60`.
4. Runs the load **continuously across three phases**: `PRE_SNAP_SECS` (default 3)
   before triggering the snapshot, through the marker sweep, and then — after
   **waiting for the cut to actually finish** (the initiator's artifact appearing
   locally, up to `SNAP_WAIT_SECS`) — for `POST_SNAP_SECS` (default 5) *more*, so
   the system is shown still processing operations **after** the snapshot
   completes. The load is then stopped via a sentinel file (`LOAD_MAX_SECS` is a
   backstop so it can never run forever).
5. Re-verifies the total returns to `60`.

Tune the load with env vars, e.g.
`LOAD_THREADS=6 POST_SNAP_SECS=10 ./test/test_6counter.sh`.

> **Why multithreaded (but only moderate)?** A single, one-at-a-time transfer
> loop leaves the channels empty almost always: RUDP delivers and ACKs each
> CREDIT in well under a millisecond, so the marker sweep practically never lands
> on a message in transit and the recorded channel state comes back empty.
> Running transfers concurrently keeps the channels busy so the cut actually
> captures in-flight state — watch a sidecar's log during the snapshot for
> `Caching in-flight message seq N from <peer>`, which **is** recorded channel
> state. But do **not** firehose it: the `mesh_proxy` is single-threaded asyncio
> and `print()`s on every packet, so a few hundred transfers/s overruns the
> tunnel socket, head-of-line-blocks a channel, and snowballs into an unclearable
> `[retx] seq … to 10.24.24.11` storm (counters diverge, the total never settles
> back to 60). The marker-sweep window is tens-to-hundreds of ms (it includes the
> CRIU checkpoint), so the default ~80/s is plenty. If you see a runaway retx
> storm or `total` stuck below 60, you are driving too hard — lower
> `LOAD_THREADS` or raise `LOAD_SLEEP`.

> The driver assumes it runs on physical node A (it initiates the snapshot
> locally, `INIT_NODE=a`). Run it on the node whose letter is `a`.

Expected tail:

```
PASS: total conserved at 60 across a global snapshot taken under live load.
```

The load generator sends `counter.py`'s exact `TRANSFER` wire format (fire and
forget); `counter.py` itself is unmodified. Its `sum` verb only spans 3 nodes, so
the driver sums the six via `state`.

## 3. Inspect the snapshot (PER NODE)

Each node wrote only its own pieces to its own local `/tmp`:

```bash
# on each node:
curl -s http://10.99.0.1:8989/snapshot/<snap_id>
ls -l /tmp/snapshot-<snap_id>-counter-*        # this node's three .json + .tar.zst
```

You should see, across the two nodes, all six artifacts:
`counter-a/b/c/d/e/f`, each with a `.json` (channel-state cut) and a `.tar.zst`
(app CRIU image).

## 4. Optional: restore (PER NODE, not driven by the test)

Restore is per-node and independent of this test. On each node, restore that
node's own counters with their letters:

```bash
# on node A:
./run_restore.sh <snap_id> a b c
# on node B:
./run_restore.sh <snap_id> d e f
```

Then confirm the total was conserved across snapshot + restore:

```bash
# from any one node:
./test/verify_sum.sh            # opens a control container, checks the 6 sum to 60
```

`verify_sum.sh` reads the live post-restore values without resetting, so it
actually verifies the restore. (Do NOT re-run `test_6counter.sh` to check a
restore — it resets every counter to 10 first, which would mask whether the
restored values were correct.)

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
- **Stale-ARP black holes (the "always missing `.11`" symptom).** A node restored
  by an earlier run (e.g. `counter-b`/`.11` via `test_local_b.sh`) comes back with
  a MAC that peers still have cached, so traffic to it black-holes until the entry
  is re-resolved. `test_6counter.sh` now flushes the ARP cache of every local
  sidecar netns (`ip neigh flush all`) at startup, which forces a fresh ARP on the
  next send — this is why it heals on its own. Note the flush can only reach
  containers on the node running the driver; that is enough here because every
  sender that targets a counter in this test (the control container and
  `counter-a..c`) lives on node A. If you ever hit this by hand, use
  `sudo podman exec sidecar-<x> ip neigh flush all` — **not** the `ping` workaround
  in `RUNBOOK.md`: the alpine sidecar image installs only `iptables`+`iproute2`,
  so `ping` isn't present (`ip` is).
