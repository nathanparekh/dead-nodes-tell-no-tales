# RUNBOOK (6-node): snapshot-under-load + verify the cut's contents

A focused, copy-pasteable runbook for the **6-container** Chandy-Lamport test.
It runs SIX counter apps (2 per node across 3 EC2 nodes), drives continuous
money-transfer transactions BEFORE, DURING, and AFTER a global snapshot, takes
the cut mid-load, and then VERIFIES THE SNAPSHOT'S CONTENTS (the recorded
channel-state artifacts) for completeness and consistency.

This is the 6-node companion to `RUNBOOK.md` (the 3-node restore walkthrough).
The 3-node test is unchanged; everything here is additive. Where this runbook
differs from the 3-node one, it is because the member set is six IPs and the
membership must be propagated to every sidecar — see step 3.

## Overview

- 6 apps `counter-a` .. `counter-f`, 2 per node, app UDP port `5000`.
- The mesh control container (`10.24.24.200`, NOT a member) dispatches a steady
  ring of transfers. Each `transfer FROM ... TO ... AMOUNT` debits FROM and
  sends a server→server CREDIT to TO, so **total money is conserved** by every
  transfer (sum of all six counters is constant = `6 * per_node`, default 60).
- A global snapshot is triggered mid-load. Each node records its OWN cut to its
  OWN local `/tmp` (there is no shared store), capturing per-peer
  `send_seq`/`recv_seq` coordinates and any in-flight server→server CREDIT
  messages on the wire.
- `verify_snapshot.py` then checks the collected JSON artifacts: every member
  present and `complete`, every directed channel consistent (sender's `send_seq`
  == receiver's `recv_seq`), and the in-flight CREDIT payloads decode cleanly.

### Member / IP map (FIXED — every node must agree)

| suffix | container  | mesh IP        | suggested node |
|--------|------------|----------------|----------------|
| a      | counter-a  | `10.24.24.10`  | A (initiator)  |
| b      | counter-b  | `10.24.24.11`  | B              |
| c      | counter-c  | `10.24.24.12`  | C              |
| d      | counter-d  | `10.24.24.13`  | A              |
| e      | counter-e  | `10.24.24.14`  | B              |
| f      | counter-f  | `10.24.24.15`  | C              |

Mesh IP rule (same as `build.sh`): last octet = `(ord(suffix) - ord('a')) + 10`,
mesh base `10.24.24`. The control container stays at `10.24.24.200` (not a
member). **Node placement is the operator's choice** — `build.sh` is run per
node; the harness does not enforce which physical node hosts which letter, only
the IPs matter. The table above is the suggested 2-per-node layout used below.

The full member set for `MESH_MEMBERS` is exactly:

```
10.24.24.10,10.24.24.11,10.24.24.12,10.24.24.13,10.24.24.14,10.24.24.15
```

---

## 1. Prerequisites

Same environment as the 3-node `RUNBOOK.md`:

- **VXLAN overlay:** mesh subnet `10.24.24.0/24` routable across all three
  nodes; UDP `9001` open node-to-node (the sidecar tunnel). The proxy needs no
  changes — VXLAN preserves the mesh source IP, so peer identity is consistent.
- **Podman mesh network:** every node has the identical macvlan network `vlan`
  (parent `br0`, subnet `10.24.24.0/24`, gateway `10.24.24.1`). Confirm with
  `sudo podman network inspect vlan`. `build.sh`/`mesh_ctl.sh` honor `MESH_NET`
  (default `vlan`); leave it unset unless you renamed the network.
- **Toolchain:** `podman` + `CRIU` + `sudo` on each node; repo git-cloned on
  each node, scripts run from the repo root.
- **Receiver port:** the host-local breakout receiver binds `10.99.0.1:8989` on
  each node (its OWN bridge gateway — local, not shared). `build.sh` starts it.

---

## 2. Deploy (PER NODE) — EXPORT `MESH_MEMBERS` FIRST

**Export `MESH_MEMBERS` with all six IPs BEFORE running `build.sh`, on EVERY
node:**

```bash
export MESH_MEMBERS=10.24.24.10,10.24.24.11,10.24.24.12,10.24.24.13,10.24.24.14,10.24.24.15

# node A:
./build.sh a A
./build.sh d A

# node B:
./build.sh b B
./build.sh e B

# node C:
./build.sh c C
./build.sh f C
```

**Why `MESH_MEMBERS` is critical.** Each sidecar only RUDP-tunnels and records
traffic for IPs it knows are mesh members; non-members are treated as plain,
best-effort, and are NEVER captured by the cut. `build.sh` passes
`MESH_MEMBERS` to every sidecar. Its built-in default is the original 3-node set
(`10.24.24.10,10.24.24.11,10.24.24.12`) so the 3-node test keeps working — which
means if you DON'T export the full six here, `.13`/`.14`/`.15` (counters d/e/f)
go plain and are silently dropped from the global snapshot. Export it on **every
node** so all six sidecars agree on the member set.

**Running `build.sh` twice per node is expected.** Each call deploys ONE app +
its sidecar; the per-node receiver and breakout anchor are idempotent, so the
second call just adds the second app+sidecar and leaves the receiver in place.

After this, each node runs its two `counter-<suffix>` + `sidecar-<suffix>` and a
receiver on `10.99.0.1:8989`.

---

## 3. Run the test (on the control / initiator node, e.g. node A)

The control node is the one hosting the `mesh-ctl` control container AND the
initiator counter (default letter `a` ⇒ node A). One command does the whole
run:

```bash
./test_6node_snapshot.sh snap6 a 10 8 8
```

Args: `[snapshot_id] [initiator_letter] [per_node] [before_s] [after_s]`
(defaults `snap6 a 10 8 8`). To auto-collect the other nodes' artifacts and
verify in one shot, set `NODES_SSH` to the OTHER two nodes' ssh targets:

```bash
NODES_SSH="user@nodeB user@nodeC" ./test_6node_snapshot.sh snap6 a 10 8 8
```

What it does, in order:

1. `./mesh_ctl.sh bootstrap6 10` — reset all six to `per_node`, warm the
   `.10→.11→…→.15→.10` ring so every sidecar has live peer state, and verify the
   starting total is `6*per_node` (= 60). Aborts if this fails.
2. Starts `./mesh_ctl.sh load <before_s+after_s+30> 0 1` in the BACKGROUND so
   transfers flow before, during, and after the cut. The loop runs INSIDE the
   control container as one long-lived `loadgen` process (no per-transfer
   `podman exec`), sustaining a high transfer rate bounded by mesh RTT rather
   than exec startup. It is halted promptly at teardown via `stoploadgen` and
   also self-terminates by duration.
3. `sleep before_s` — transactions flowing BEFORE the cut.
4. `./trigger_snapshot.sh a snap6` — node A initiates and floods markers; each
   node records its own cut to its own local `/tmp`.
5. `sleep after_s` — transactions flowing AFTER the cut, then stops the load.
6. Lists this node's own artifacts and runs a LIVE conservation sanity check
   `./mesh_ctl.sh sum6 60` (the live total stays 60 because every transfer
   conserves).
7. **Collection + verify:** if `NODES_SSH` is set it gathers all six JSONs into
   `./snap-snap6/` and runs `verify_snapshot.py`; otherwise it prints the manual
   scp + verify commands (see step 4).

---

## 4. Collect + verify manually (if you did NOT set `NODES_SSH`)

Each node holds only its OWN two `*.json` artifacts on its OWN local `/tmp`, so
you must gather all six into one directory before verifying. From the control
node:

```bash
mkdir -p ./snap-snap6

# this node's own two artifacts (node A: counters a, d):
cp /tmp/snapshot-snap6-counter-*.json ./snap-snap6/

# pull the other nodes' artifacts (adjust ssh targets to your hosts):
scp 'user@nodeB:/tmp/snapshot-snap6-counter-*.json' ./snap-snap6/
scp 'user@nodeC:/tmp/snapshot-snap6-counter-*.json' ./snap-snap6/

# you should now have six files: counter-a..f
ls -1 ./snap-snap6/snapshot-snap6-counter-*.json

# verify the cut's contents:
python3 verify_snapshot.py ./snap-snap6 snap6
```

`verify_snapshot.py <dir> <snapshot_id>` defaults to the six members and mesh
base `10.24.24`. Optional flags: `--members ip,ip,...`, `--mesh-base 10.24.24`,
`--min-inflight N` (fail if fewer than N in-flight messages were captured).

**PASS criteria** (the report ends in `RESULT: PASS`, exit 0):

- `nodes: 6/6 complete` — all six members present and every artifact `complete`
  (not `aborted`).
- `channels: 30/30 consistent` — for every ordered member pair (S→R, 6*5 = 30),
  the sender's `peers[R].send_seq` equals the receiver's `peers[S].recv_seq`.
  Any mismatch prints e.g. `MISMATCH 10.24.24.10->10.24.24.11 send=7 recv=6`.
- `in-flight: <m> messages, <amt> total credit captured` — the recorded
  server→server CREDIT payloads decode cleanly (`CREDIT <txid> <from> <amount>`),
  with a few example payloads shown.

Exit codes: `0` PASS, `1` FAIL, `2` usage / IO error.

> NOTE: money-conservation (the sum of the live counters) is NOT verifiable from
> these JSON artifacts alone — the counters live in the per-node CRIU images, not
> the channel-state JSON. For the conservation proof, use the restore capstone
> below (or the live `sum6` check, which the test already runs).

---

## 5. OPTIONAL conservation capstone (the money-total proof)

The JSON verify proves the cut is a consistent global snapshot. To ALSO prove
money was conserved end-to-end, restore the whole system from the snapshot and
confirm the total is still 60.

Restore runs PER NODE, each with that node's OWN letters. `run_restore.sh`
accepts multiple letters in one call, so pass both of a node's letters at once:

```bash
# on node A:
./run_restore.sh snap6 a d

# on node B:
./run_restore.sh snap6 b e

# on node C:
./run_restore.sh snap6 c f
```

Per node and per letter this restores the app from its local CRIU image
(`/tmp/snapshot-snap6-counter-<letter>.tar.zst`) and starts a fresh
restore-mode sidecar that loads that letter's artifact, restores per-peer
`send_seq`/`recv_seq`, replays the recorded channel once in seq order, then
resumes live traffic. Then, from the control node:

```bash
./mesh_ctl.sh sum6 60
```

A settled total of `60` is the end-to-end conservation proof that the JSON-only
verify cannot give you: the global cut + per-node restore lost and duplicated no
in-flight credits.

---

## 6. Gotchas

- **`MESH_MEMBERS` must list all six on EVERY node, exported BEFORE `build.sh`.**
  Otherwise `.13`/`.14`/`.15` (d/e/f) fall back to plain best-effort traffic, are
  never RUDP-recorded, and are silently dropped from the snapshot. This is the
  single most common 6-node mistake (the 3-node default hides it).
- **Collect ALL six JSONs.** Each node holds only its own two artifacts on its
  own local `/tmp`; `verify_snapshot.py` needs all six in one directory or it
  reports missing members and FAILs completeness.
- **`build.sh` runs twice per node** (one app+sidecar each). The receiver/anchor
  are idempotent; the second run does not disturb the first app.
- **The live `sum6` stays 60 throughout.** Every transfer debits and credits the
  same amount, so the total never moves even under continuous load — a non-60
  live sum means a transfer was lost, not that the snapshot is wrong.
- **Warming is hygiene, not a correctness requirement.** `bootstrap6` warms the
  `.10→…→.15→.10` ring so every sidecar has live RUDP peer state before the cut.
  But marker fan-out and the recording set are derived from the STATIC
  `MESH_MEMBERS` list (not from lazily-learned peers), so an unwarmed member is
  still marked and recorded — the ring warm just exercises the RUDP path and
  creates real in-flight state for the cut to capture. (The generic
  `trigger_snapshot.sh` reminder about warming "every directed pair" predates
  static membership and overstates the risk for this test.)
- **Initiator letter = control node's letter.** Run `test_6node_snapshot.sh` on
  the node that hosts both `mesh-ctl` and the initiator counter (default `a` ⇒
  node A); the trigger drives that node's LOCAL receiver.
