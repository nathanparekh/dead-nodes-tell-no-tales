# RUNBOOK: 6-container plain-CRIU counterexample (2 EC2 nodes)

The counterexample to `RUNBOOK_6counter.md`: the **same 6-counter topology and
the same continuous load**, but with **no sidecar proxies and no Chandy-Lamport
cut** — each container is captured with bare, uncoordinated CRIU
(`podman container checkpoint`). After restore, the conserved total is
**expected to be violated**: in-flight credits were recorded in no image, and
the per-container dumps cannot agree on a point in time. This is the
demonstration of *why* the sidecar snapshot exists.

Same images, same `counter.py`, same VXLAN overlay as `RUNBOOK_6counter.md`.
No breakout network/receiver is used: capture and restore are direct `podman`
calls per node. No SSH; per-node steps run on their node.

## Topology

Identical to `RUNBOOK_6counter.md` (a–f → `.10`–`.15`, 3 per node), except the
counters run **without sidecars** (raw UDP on the routable mesh) and the
control container is the sidecar-less `mesh-ctl-np` at `10.24.24.201`
(`mesh-ctl`'s TPROXY sidecar would tunnel RUDP at counters with nothing to
de-tunnel it).

## 1. Deploy — run ON EACH node with that node's letter

```bash
# on node A:
./test/deploy6_noproxy.sh A      # counter-a/b/c, NO sidecars
# on node B:
./test/deploy6_noproxy.sh B      # counter-d/e/f, NO sidecars
```

Don't mix modes: a node deployed with `deploy6.sh` (sidecars) and a node
deployed with `deploy6_noproxy.sh` cannot talk to each other (RUDP tunnel vs
raw UDP). Redeploy both nodes with the matching script when switching.

## 2. Run the counterexample — driver on node A

```bash
# on node A:
./test/test_6counter_criu.sh                 # or: ./test/test_6counter_criu.sh myid
# on node B, while the driver's load is flowing (POST_SNAP_SECS=30 buys slack):
./test/criu_capture.sh criu6 d e f
```

The driver mirrors `test_6counter.sh`: reset to 10 each (total 60), warm the
ring, run the multithreaded load, and — while the load is flowing — checkpoint
this node's three counters with plain CRIU, **in parallel** (as close to
"simultaneous" as an uncoordinated capture can get). It then keeps the load
running, stops it, and verifies the **live** total is still 60
(`--leave-running` means the capture disturbed nothing — any loss seen later
is the capture's fault, not the load's).

Capturing node B under the same load gives the canonical lost-in-flight demo,
but ANY timing works: with no coordination protocol the six images can never
form a consistent cut — that is the point.

Artifacts land per node in `/tmp/criu-<id>-counter-<letter>.tar.zst` (the
`criu-` prefix keeps them apart from the sidecar flow's `snapshot-` images).

## 3. Restore — PER NODE — and verify the violation

```bash
# on node A:
./test/restore_criu.sh criu6 a b c
# on node B:
./test/restore_criu.sh criu6 d e f
# then, from one node:
./test/verify_sum_noproxy.sh        # EXPECT: "VIOLATED: total X != 60"
```

`restore_criu.sh` is bare `podman container restore` — no restore-mode sidecar,
no channel replay. `verify_sum_noproxy.sh` polls until the total is *stable*
and reports `CONSERVED` or `VIOLATED` with the delta; for this counterexample
`VIOLATED` (exit 1) is the expected, demonstrative outcome.

Contrast with the sidecar flow on the same topology
(`test_6counter.sh` → `run_restore.sh` per node → `verify_sum.sh`), where the
Chandy-Lamport cut + recorded-channel replay returns the total to exactly 60.

## Gotchas

- **The live system stays correct; only the restore is broken.** The driver's
  final live check still settles at 60. The inconsistency exists only inside
  the uncoordinated images, so it surfaces exclusively after restore.
- **`VIOLATED` can land either side of 60.** Lost in-flight credits push the
  total down; rolling a counter back past transfers its peers already absorbed
  can push it up. Any stable total ≠ 60 demonstrates the point.
- **If the total comes back exactly 60**, the channels happened to be empty at
  every dump (unlikely under the default load, but possible). Re-run with a
  heavier load, e.g. `LOAD_THREADS=16 ./test/test_6counter_criu.sh`.
- **Stale MAC after restore is handled by recreating the control.** A restored
  counter has a fresh MAC (podman ignores macvlan `mac=`), and with no sidecars
  there is no netns to `ip neigh flush` through. `verify_sum_noproxy.sh` (and
  the driver) always recreate `mesh-ctl-np`: a fresh netns has an empty ARP
  cache, and its ARP requests re-announce its MAC to every counter.
- **Artifacts and restore are PER NODE**, exactly like the sidecar flow: no
  shared store, run each node's restore on that node.
