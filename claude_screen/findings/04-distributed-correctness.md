# Findings — distributed-systems correctness (end-to-end migration)

These concern whether the *system* preserves its invariant (`sum == 30`) across a
checkpoint/restore migration. They are derived by tracing the code paths; the most
important (D1) follows directly from the EXTERNAL-routing behavior proven structurally in
M6. A full multi-node CRIU run was out of scope (see ASSUMPTIONS.md).

---

## D1 — The headline test's premise fails: the credit is dropped, not queued  [HIGH, confidence high]
**Where:** `tests/test_local_b.sh:23-44` vs `mesh_proxy.py` routing (`:255-303`, `:193-208`).
**Scenario the test runs:** reset A/B/C=10; remove **both** `counter-b` and `sidecar-b`;
then `counter transfer A->B 7` while B is gone; restore; expect `sum==30` "because the
sidecar queues & retries."
**What actually happens:** At transfer time A's sidecar has no route to B yet. It probes
B's tunnel port (`__PROBE__` to 10.24.24.11:9001) — but **sidecar-b was removed**, so no
`__PROBE_ACK__`. After `0.1s` the route is set `EXTERNAL` (`:200-202`), and the buffered
CREDIT is flushed **raw via a spoof socket to a down host** (`:204-208`) and lost.
**EXTERNAL packets are never added to `unacked`, so there is no retransmission** (only the
MESH branch enqueues retransmits, `:298`). A already debited (C1), so the system ends at
A=3, B=10, C=10 → `sum=23 ≠ 30` → the test should FAIL, and the "RUDP ensures no credits
vanish" claim is false for this exact path.
**Why it matters:** The central demonstration of the project doesn't hold up against its
own code. Even if `sidecar-b` were left running, success would also require MESH retransmit
to survive the checkpoint of `sidecar-b` and correct seq-state restore.
**Fix:** For in-mesh destinations, keep buffering + retransmitting across probe failure
(treat a downed peer as "MESH, temporarily unreachable", not EXTERNAL); only fall back to
raw send for genuinely non-mesh addresses.

## D2 — Checkpoint/restore ordering of two containers sharing one netns is unsound  [MEDIUM → LOW, see 10-correctness-audit.md]
> **AUDIT: overstated.** Containers aren't removed during checkpoint, and restore already does
> netns-owner-first (`test/test_local_b.sh:37` then `:38`). Latent/undocumented ordering
> dependency, not a present failure. Downgrade to low.
**Where:** `tests/test_local_b.sh:26-38`; sidecar launched `--network container:counter-b`
(`build.sh:42-47`).
**What:** The test checkpoints `counter-b` first (default checkpoint **stops** it), then
checkpoints `sidecar-b` whose network namespace is *owned by* the now-stopped `counter-b`.
Checkpointing the namespace-borrower after the owner is gone is fragile/likely to fail; on
restore, `sidecar-b`'s `--network container:counter-b` dependency must resolve to a
container with the original id, which a fresh `restore` may not provide.
**Fix:** Checkpoint/restore the pair as a unit (a pod), or restore the netns owner first
and re-establish the join explicitly; document the required ordering.

## D3 — `checkpoint` omits `--tcp-established` though `restore` uses it (and the comment says to)  [MEDIUM → NIT, see 10-correctness-audit.md]
> **AUDIT: functionally moot.** Real asymmetry, but there are **no `SOCK_STREAM`/TCP sockets**
> in the deployed code (all UDP), so the flag is inert here. Doc/consistency nit.
**Where:** `tests/test_local_b.sh:23-27` (checkpoint, no flag) vs `:37-38` (restore, with
flag). The comment at `:24` says to use it "to freeze network interface sockets properly."
**Why it's a bug/risk:** podman/CRIU expect consistent `--tcp-established` handling between
checkpoint and restore when established TCP connections exist. The data path here is UDP so
it may be moot, but the asymmetry is a latent failure and the comment is misleading. (The
no-proxy variant `test_without_proxy/test_local_b.sh:27` also omits it on checkpoint.)
**Fix:** Pass `--tcp-established` on both, or neither, consistently.

## D4 — After restore, the sender keeps B pinned EXTERNAL during `PROBE_COOLDOWN`  [MEDIUM, confidence medium]
**Where:** `mesh_proxy.py:257-262`, `PROBE_COOLDOWN=5.0` (`config.py:8`).
**What:** Once A marks B `EXTERNAL` (during the offline window) with a recent
`last_probe_time`, A won't re-probe B for 5s even after B + sidecar-b are restored. Any
traffic in that window stays EXTERNAL (no mesh, no retransmit).
**Fix:** Reset routing/probe state when a peer reappears; probe on demand after failure.

## D5 — The cut is uncoordinated, so in-flight tunnel state is inconsistent across migration  [LOW–MEDIUM, confidence medium]
**Where:** in-band Chandy-Lamport (intended coordinator) is broken/unreachable (S-series,
C9); the test uses bare `podman checkpoint` with no quiesce.
**What:** `send_seq`/`recv_seq`/`unacked`/`recv_buffer` only migrate cleanly if the sidecar
is frozen at a consistent point relative to the app and the peer. With an uncoordinated
checkpoint, packets/ACKs in flight at the instant of the cut are lost or duplicated, and
the restored proxy may re-probe/reset routing.
**Fix:** Quiesce the data path (working snapshot protocol) before checkpoint, or accept and
document at-least-once semantics + require app-level idempotency (which C2 lacks).

## D6 — (verified, fragile-but-OK) tunnel seq dedup across restore  [INFO, confidence medium]
The receiver advances `recv_seq` in the same synchronous callback as delivery
(`mesh_proxy.py:94-103`, no `await` between), so a checkpoint cannot interleave "delivered
but not counted." Thus a post-restore retransmit of an already-delivered seq is correctly
dropped — *provided* the sidecar's memory was checkpointed atomically. Recorded as a
checked item; the guarantee is real but depends on D2/D5 holding.
