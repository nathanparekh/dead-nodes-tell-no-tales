# Token Ring — Application Plan

A distributed mutual-exclusion app (token ring) to replace/complement `counter`, whose
**checkpoint is correct only because of the proxy's channel-state recording**. This document
is the design; implementation order is in §11.

---

## 1. Goal & success criterion

Build an app where a CRIU memory checkpoint of every node is **provably insufficient** to recover
a consistent global state, and the proxy's recorded in-flight channel state (`channel_states` in
`snapshot_handler.py`) is what closes the gap.

The success criterion is a single falsifiable experiment (§9):

> Take one snapshot. Kill all nodes. Restore twice from the **same** CRIU images:
> (a) **with** the proxy-recorded channel replayed → system is correct;
> (b) **without** it (CRIU memory only) → mutual-exclusion is violated.
>
> If (a) passes and (b) fails, the checkpoint depends on the proxy. If (b) also passes, the app
> is no better than the work queue and we've failed the bar.

## 2. Why this passes the bar the work queue failed

The work queue was trivially recoverable because the **sender retains what it sent** (a dispatch
log) and **re-delivery is idempotent** — so end-to-end retransmit recovers any lost in-flight
message with zero proxy involvement. Token ring defeats both escape hatches:

- **Sending transfers ownership.** When a node forwards the token it sets `have_token = False`. It
  does not hold a re-sendable copy — it *gave the token away*. There is no authoritative log to
  replay from.
- **Naive retransmit is unsafe, not redundant.** If a node "helpfully" re-sends a token it isn't
  sure arrived, and it *did* arrive, the system now has **two tokens** → two nodes in the critical
  section → mutual exclusion broken. The reflexive app-level fix actively produces a wrong answer.
- **The in-flight payload is non-regenerable.** The token carries an `epoch` (§5). While the token
  is on the wire, that epoch exists in exactly one place — the channel — because the previous holder
  cleared it on send and the next holder hasn't received it yet. Lose the message and no node can
  reconstruct the epoch; a guess collides with an already-used epoch.

The only correct recovery is a **consistent global cut** that locates the single token (and its
epoch) wherever it is — including on the wire. That cut is exactly what the proxy's Chandy–Lamport
snapshot provides. To reproduce it inside the app you would have to build reliable, ack'd,
exactly-once handoff with a global-cut protocol — i.e. reimplement the proxy.

## 3. System model & topology

- **3 nodes A, B, C** in a unidirectional ring `A → B → C → A`, reusing the existing deployment
  (mesh subnet `10.24.24.0/24`, IPs `.10/.11/.12`, one sidecar per node — see `build.sh`).
- App sends plain UDP to the successor's mesh IP:port. The sidecar TPROXY-intercepts, tunnels with
  **reliable, in-order per-peer delivery**, and spoof-delivers on the far side.
- **Key fit:** the tunnel is FIFO per peer (`PeerState.recv_seq` + reorder buffer). Chandy–Lamport
  *requires* FIFO channels. The proxy gives us that for free — markers can never overtake a token
  sent before them on the same channel. This is why the proxy is a natural host for this app.

## 4. Application state (what CRIU captures)

Per node, in memory:

| field | meaning |
|---|---|
| `name` | A / B / C |
| `have_token: bool` | does this node currently hold the token |
| `epoch: int` | the epoch carried by the token *while held* (meaningless when `have_token=False`) |
| `witnessed: set[int]` | epochs in which **this node** entered the critical section |
| `next_host, next_port` | ring successor |
| `last_seen_token: float` | for the (naive) loss-recovery timer (§9, control) |

CRIU dumps this verbatim. Note what it **cannot** see: a token currently on the wire.

## 5. Wire protocol (text, `counter`-style)

```
holder → successor :  TOKEN <seq> <epoch>          # the token + its non-regenerable payload
query              :  STATUS                         → "STATUS <name> have=<0|1> epoch=<e> cs=<csv of witnessed>"
snapshot trigger   :  __START_SNAPSHOT__             # intercepted by sidecar, never reaches app (see _handle_local_intercept)
```

`<seq>` is an app-level hop counter (debugging / FIFO sanity). The proxy adds its own transport seq.

## 6. Token lifecycle

On receiving `TOKEN <seq> <epoch>`:

1. `have_token = True`; `epoch = epoch + 1`.
2. **Enter critical section:** append `epoch` to `witnessed`. (The CS "work" is just recording the
   epoch — the safety property is that no other node ever records the same epoch.)
3. Hold for `HOLD_MS` (tunable; widens the in-flight window for the demo).
4. Forward `TOKEN <seq+1> <epoch>` to the successor.
5. `have_token = False`. The epoch now lives only in the outbound message until the successor
   receives it.

Exactly one node boots with `have_token=True, epoch=0`. Steady state: the token (and its epoch)
circulates, `witnessed` sets across nodes partition `{1, 2, 3, …}` with no overlap.

## 7. Invariants & how they're checked

| invariant | statement | checked by |
|---|---|---|
| **Conservation (safety)** | exactly one token exists across {node states} ∪ {channel states} | `verify` after restore: exactly one `have=1` (token replayed back into a node) |
| **Mutual exclusion** | no epoch appears in two nodes' `witnessed` sets | `verify`: union of `witnessed` has no duplicates |
| **Progress / no gaps** | union of `witnessed` is contiguous `{1..max}` | `verify`: sorted union has no holes |

A lost token shows as **zero** `have=1` (conservation fail). A duplicated/guessed token shows as a
**repeated epoch** across nodes (mutual-exclusion fail). Both are detectable from node state alone
*after* restore — we don't need to read the proxy's internals, only its *effect* (replay).

## 8. Snapshot integration (no proxy code changes for the happy path)

Rides the existing mechanism end to end:

1. A node sends `__START_SNAPSHOT__` to a mesh peer → its sidecar's `_handle_local_intercept`
   catches it → `SnapshotController.process_message` sets `is_snapshotting`, fires the out-of-band
   CRIU dump (`_trigger_app_snapshot_out_of_band` → host agent `:9090/checkpoint`), and broadcasts
   markers to peers.
2. Each sidecar records messages arriving on a channel after its own state until that channel's
   marker arrives — i.e. the in-flight `TOKEN` is cached in `channel_states`.
3. On `_finish_global_snapshot`, recorded messages are replayed (spoof-delivered) into the
   (restored) app, which processes the `TOKEN` through the normal handler in §6.

The token therefore re-materialises in the successor's memory **only because the proxy held it**
across the cut.

## 9. The demonstration (centerpiece)

### 9a. Deterministically catch the token *on the wire*

The token must be in `channel_states` (CRIU-invisible), not resting in a node, for the demo to bite.
Achieve this without touching the proxy:

- Add **artificial link latency** with `tc qdisc add … netem delay 1500ms` on the `A → B` hop. This
  opens a wide, controllable window where the token is provably in flight.
- **Initiate the snapshot from C** (the node "behind" the token), token sitting at A about to hand
  to B. Markers are small and fast; they reach A and B while the delayed `TOKEN A→B` is still
  crossing. B records its state (`have_token=False`) *before* the token arrives, so when the token
  finally lands it is recorded as **channel state on A→B**. (FIFO guarantees the marker A→B, sent
  after the token, arrives after it — closing the recording.)
- `HOLD_MS` and the netem delay make this race deterministic, not flaky. Risk & fallback in §13.

### 9b. The two restores (same CRIU images)

| restore | procedure | result |
|---|---|---|
| **(a) proxy-consistent** | restore all nodes from CRIU **and** let `_finish_global_snapshot` replay the recorded channel | token reappears at B with `epoch=k`; `verify` → **PASS** |
| **(b) CRIU-only (control)** | restore all nodes from CRIU, **discard** the recorded channel | no node has the token → see below |

The control is *not* a proxy code change — it's the same checkpoint data with the channel-replay
step omitted, which is exactly "what a naive CRIU-only checkpoint would have given you."

### 9c. Make the control fail *unsafely* (the punchline)

Give the app the obvious, naive liveness fix: **loss recovery** — if a node hasn't seen the token
for `T` seconds it assumes it's lost and regenerates one at `epoch = (max epoch it knows) + 1`.

- **With the proxy (a):** the token is never actually lost (it was captured and replayed), so the
  timer never fires. No regeneration, no duplicate epoch. Correct.
- **Without the proxy (b):** the token *is* gone. The timer fires, a node regenerates a token — but
  it doesn't know the in-flight epoch `k`, so it reuses an epoch already in some node's `witnessed`
  → **two nodes record the same epoch → mutual exclusion violated.** `verify` → **FAIL**.

This is the whole argument made runnable: the natural app-level fix is *unsafe* without a consistent
global cut, and the proxy is what supplies the cut.

## 10. CLI surface (mirrors `counter.py`)

```
tokenring node     NAME PORT NEXT_HOST NEXT_PORT HAS_TOKEN HOLD_MS [LOSS_TIMEOUT_MS]
tokenring status   HOST PORT
tokenring snapshot NEXT_HOST NEXT_PORT          # sends __START_SNAPSHOT__ to a mesh peer (run inside a node netns)
tokenring verify   N  A_HOST A_PORT  B_HOST B_PORT  C_HOST C_PORT
```

`verify` queries every node's `STATUS` and asserts the three invariants in §7, printing
`PASS`/`FAIL` with the offending epoch(s) on failure (same shape as counter's `sum`).

## 11. Implementation order (milestones)

1. **M1 — ring core.** `tokenring node` + `status`; token circulates; `witnessed` fills. No proxy,
   localhost, 3 processes. Assert invariants by hand.
2. **M2 — under sidecars.** Deploy on the mesh (adapt `build.sh`); confirm the token survives the
   tunnel and FIFO ordering holds.
3. **M3 — snapshot happy path.** Wire `snapshot`; confirm a snapshot taken while the token rests in
   a node round-trips through CRIU + replay.
4. **M4 — catch-on-the-wire.** Add `tc netem`; initiate-from-behind; confirm the token lands in
   `channel_states` (log inspection) and replay restores it. This is restore (a).
5. **M5 — the control & punchline.** Add naive loss-recovery; script restore (b) (CRIU-only, no
   replay); confirm `verify` FAILs with a duplicate epoch. Restore (a) PASSes.
6. **M6 — harness.** One script: load → snapshot → kill → restore(a) → verify; and a `--criu-only`
   flag for restore(b). Assert PASS/FAIL respectively.

## 12. What changes outside the app

- **App:** new `src/tokenring.py` (single file, counter's skeleton).
- **Proxy:** ideally **zero changes** — it already records & replays channel state. (If the host CRIU
  agent / restore path isn't already exercised by counter, that's shared plumbing, not token-ring
  specific.)
- **Harness:** `tc netem` setup/teardown; a restore script with the CRIU-only toggle.

## 13. Risks & edge cases

- **Winning the race deterministically (M4).** If the marker loses to the token, the token lands in
  B's CRIU state — a *valid* snapshot, but it doesn't exercise channel state, so the demo doesn't
  bite. Mitigation: netem delay ≫ marker RTT, plus `HOLD_MS`. Fallback: a debug hook that
  SIGSTOPs B between state-record and token-arrival, or pauses delivery — last resort, it muddies
  the "no proxy changes" story.
- **Tunnel retransmit duplicating the token.** The proxy is at-least-once; a redelivered `TOKEN`
  could mint a second token. The app must **dedup by `<seq>`** (apply each token hop once) — this is
  load-bearing for safety, and also what keeps replay-on-restore from double-applying.
- **Marker broadcast vs ring edges.** Markers flood all proxy peers, not just ring successors;
  confirm a node's first marker can arrive on a channel other than the token's, which is what lets B
  record state before the token (the §9a mechanism). Validate the actual peer set on the 3-node ring.
- **Initiator choice.** The demo only works initiated from "behind" the token. The harness must know
  where the token is (query `status` first) and pick the initiator accordingly.
- **Restore correctness of CRIU itself** is assumed (shared with counter). If CRIU restore is flaky,
  isolate that before trusting the token results.

## 14. Open questions

1. Is the host CRIU **restore** path already built, or only checkpoint (`:9090/checkpoint`)? The demo
   needs restore; if it's missing, that's a prerequisite shared with any checkpoint-based app.
2. Should `verify` read channel state directly (tighter, but reaches into the proxy) or stay purely
   app-level via post-replay `STATUS` (cleaner, recommended)?
3. Keep `counter` alongside as the "weak dependency" contrast, or replace it?
