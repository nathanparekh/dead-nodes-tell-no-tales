# Work Queue (stateless coordinator) — Application Plan

A distributed work-dispatch app whose **checkpoint is correct only because of the proxy's
channel-state recording** — achieved by deliberately giving the coordinator **no record of
in-progress / dispatched jobs**. This is the variant that survives the "just keep a dispatch log"
objection, because there is no dispatch log to recover from.

Read alongside `TOKEN_RING_PLAN.md`; §12 compares the two honestly.

---

## 1. Goal & success criterion

Same falsifiable experiment as token ring: one snapshot, kill all, restore twice from the **same**
CRIU images —

> (a) **with** the proxy-recorded channel replayed → every job completes exactly once;
> (b) **without** it (CRIU memory only) → a job is **lost forever**.
>
> (a) passes / (b) fails ⟹ the checkpoint depends on the proxy.

## 2. The core idea — an *oblivious* coordinator

The work queue only failed earlier because the coordinator kept a dispatched/in-progress log, so it
could retransmit lost jobs without the proxy. **Remove that log.** The coordinator becomes a
**stateless router**:

- Jobs **stream in** from external clients (`SUBMIT <jobid>`); the coordinator does not hold the job
  universe.
- On `SUBMIT`, the coordinator **immediately forwards** `JOB <jobid>` to a worker (round-robin) and
  **forgets it** — no `pending`, no `inflight`, no per-job record.
- It keeps only: a round-robin cursor and a completion tally.

Consequence: a job that is **in flight on the coord→worker channel** at snapshot time exists in
*no node's* memory — the coordinator forgot it, the worker hasn't received it, the submitting client
is gone. Its **only** copy is the proxy's `channel_states`. CRIU-only restore loses it permanently;
the coordinator cannot reconstruct the gap because it never recorded what it dispatched.

## 3. System model & topology

- **1 coordinator + N workers** on the mesh subnet (`10.24.24.0/24`), one sidecar each. Reuse the
  existing 3-node deployment as coordinator + 2 workers (see `build.sh`).
- App sends plain UDP; the sidecar tunnels with reliable, **in-order** per-peer delivery (FIFO — the
  Chandy–Lamport channel assumption, satisfied for free).

## 4. Application state (what CRIU captures)

**Coordinator** (deliberately minimal):

| field | meaning |
|---|---|
| `workers: [(host,port)]` | dispatch targets |
| `rr_cursor: int` | round-robin position |
| `done_tally: int` | count of `DONE`s seen (progress only) |
| `seen_done: set[jobid]` | dedup the tally against tunnel retransmits |

**No `pending`, no `inflight`, no dispatched-job set.** This is the whole point — and what CRIU of
the coordinator cannot reveal about an in-flight job.

**Worker:**

| field | meaning |
|---|---|
| `completed: set[jobid]` | jobs this worker finished — the **ground-truth ledger** |
| `seen_job: set[jobid]` | dedup against tunnel retransmits (exactly-once processing) |
| `coord_host, coord_port` | where to send `DONE` |

## 5. Wire protocol (text, `counter`-style)

```
client → coordinator :  SUBMIT <jobid>
coordinator → worker :  JOB <jobid> <coord_host> <coord_port>
worker → coordinator :  DONE <jobid> <worker_name>
query                :  STATUS  → coordinator: "STATUS <name> tally=<n>"
                                  worker:      "STATUS <name> done=<csv of completed>"
snapshot trigger     :  __START_SNAPSHOT__       # intercepted by sidecar (see _handle_local_intercept)
```

## 6. Job lifecycle & where each job physically lives

A job id is in **exactly one** location at any instant:

```
1. in flight client→coord : SUBMIT on the wire            (transient; out of scope for snapshot)
2. in flight coord→worker : JOB on the wire               (PROXY recording)   ← invisible to CRIU
3. worker.processing      : received, dedup'd, working    (worker CRIU)
4. in flight worker→coord : DONE on the wire              (PROXY recording)
5. worker.completed       : finished                       (worker CRIU — ground truth)
```

The coordinator appears **nowhere** as a job custodian — it only routes. Location 2 is the headline:
a `JOB` the coordinator forwarded-and-forgot, not yet at the worker.

## 7. Invariant & checks

**Ground-truth ledger = union of workers' `completed` sets.**

| invariant | statement | checked by `verify` |
|---|---|---|
| **Completeness** | every submitted job is completed | `⋃ completed == {submitted ids}` |
| **Exactly-once** | no job completed twice | workers' `completed` sets are pairwise **disjoint** |

A job lost in flight (location 2, not replayed) shows as **missing from the union** → completeness
fails. Worker-side dedup (`seen_job`) guarantees the disjoint/exactly-once half even under tunnel
retransmits and replay-on-restore.

`verify` is purely app-level — it reads `STATUS` after restore and never inspects the proxy.

## 8. Snapshot integration (no proxy changes)

Identical to token ring — rides `__START_SNAPSHOT__` → `_handle_local_intercept` → marker broadcast
+ out-of-band CRIU (`:9090/checkpoint`) → per-channel recording into `channel_states` → replay on
`_finish_global_snapshot`. The in-flight `JOB` is cached and, on replay, spoof-delivered into the
restored worker, which processes it through the §6 handler.

## 9. The demonstration

### 9a. Deterministically catch a `JOB` on the wire

Same technique as token ring: `tc qdisc … netem delay 1500ms` on the coord→worker hop to widen the
in-flight window, snapshot while a `JOB` is crossing. Because the coordinator keeps no record, the
job is provably absent from both CRIU images and present only in `channel_states`.

### 9b. The two restores (same CRIU images)

| restore | procedure | result |
|---|---|---|
| **(a) proxy-consistent** | restore all from CRIU **and** replay recorded channel | the `JOB` reaches the worker, completes → appears in `completed`; `verify` → **PASS** |
| **(b) CRIU-only (control)** | restore all from CRIU, **discard** the recorded channel | the job is gone from every node; no party knows it existed → it is **never completed**; `verify` → **FAIL** (completeness) |

The control is the same checkpoint data minus the channel-replay step — i.e. what a naive CRIU-only
checkpoint yields. The coordinator **cannot** rescue it: with no dispatch log, `lost = universe −
pending − done` is uncomputable (it holds none of those sets).

## 10. CLI surface (mirrors `counter.py`)

```
workqueue coordinator NAME PORT  W1_HOST W1_PORT [W2_HOST W2_PORT ...]
workqueue worker      NAME PORT  PROC_DELAY_MS  COORD_HOST COORD_PORT
workqueue submit      COORD_HOST COORD_PORT  JOBID
workqueue status      HOST PORT
workqueue snapshot    PEER_HOST PEER_PORT        # sends __START_SNAPSHOT__ to a mesh peer
workqueue verify      N  W1_HOST W1_PORT [W2_HOST W2_PORT ...]   → PASS/FAIL
```

## 11. Implementation order (milestones)

1. **M1 — core.** `coordinator` (stateless router) + `worker` + `submit` + `status`; jobs flow,
   `completed` fills. Localhost, no proxy.
2. **M2 — under sidecars.** Deploy on the mesh; confirm jobs survive the tunnel; worker dedup works.
3. **M3 — snapshot happy path.** Wire `snapshot`; confirm a snapshot taken while jobs rest in
   workers round-trips through CRIU + replay.
4. **M4 — catch-on-the-wire.** `tc netem`; snapshot while a `JOB` is in flight; confirm it lands in
   `channel_states` and replay delivers it (restore (a)).
5. **M5 — the control.** Script restore (b) (CRIU-only, no replay); confirm `verify` FAILs with the
   missing job id; restore (a) PASSes.
6. **M6 — harness.** One script: submit load → snapshot → kill → restore(a) → verify; `--criu-only`
   flag for restore(b).

## 12. Threats to validity — how this compares to token ring (read this)

This plan satisfies "checkpoint depends on the proxy" **for the app as written**, but the dependency
is *weaker* than token ring's, and intellectual honesty requires saying why:

- **The dependency is imposed, not intrinsic.** It holds because we *chose* to make the coordinator
  oblivious. An engineer can object "just give the coordinator a dispatch log" — and they'd be right
  that it removes the need for the proxy. The rebuttal is the **transparency** argument: the proxy
  exists precisely so the app *needn't* keep that log. That's a real value proposition, but it's a
  design stance, not a forced consequence of the semantics.
- **The failure is *lost*, not *unsafe*.** Without the proxy, a job goes missing (completeness /
  liveness failure). Re-delivery here is **idempotent** (worker dedup), so any hand-rolled recovery
  that *did* exist would be safe. Contrast token ring, where naive retransmit **duplicates the
  token** → mutual-exclusion (safety) violation. A safety failure is a far stronger demonstration
  that the consistent global cut is irreplaceable.
- **Bottom line.** Token ring's dependency cannot be designed away (ownership transfer + unsafe
  retransmit); this work queue's can (add a log). Use this variant if you want the *exactly-once
  dispatch* framing and a streaming/router topology; use token ring if you want the dependency to be
  airtight. They can also coexist as a deliberate weak-vs-strong contrast.

## 13. Open questions

1. Host CRIU **restore** path — built, or only checkpoint? (Shared prerequisite with any
   checkpoint-based app.)
2. Should clients retain submitted-but-unconfirmed jobs and re-submit on timeout? That re-introduces
   recovery (at the client) — keep clients fire-and-forget to preserve the property, and note it.
3. Keep `counter` and/or token ring alongside for contrast, or replace?
