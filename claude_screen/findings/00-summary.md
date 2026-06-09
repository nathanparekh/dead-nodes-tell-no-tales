# Bug-hunt summary — all findings

~70 curated findings across the app, the checkpointing proxy, and the build/test harness.
Confidence/verdict reflects both manual analysis and an independent 100-agent review pass
that adversarially re-checked each item. **9 defects were reproduced at runtime** in
containers (`repros/`); counter.c compiles clean, so its bugs are logical/financial.

Per the task, recall is favored: `potential` items are kept and labeled, not dropped.

## Headline (fix these first)

| ID | Sev | File:line | One-liner |
|----|-----|-----------|-----------|
| **S1** | crit | snapshot_handler.py:137-152 | `process_and_deliver` called with 5 args, needs 6 → `TypeError` on every snapshot flush *(reproduced)* |
| **S2** | crit | snapshot_handler.py:143-145 | `recv_buffer` 4-tuple unpacked into 3 names → `ValueError` *(reproduced)* |
| **S4** | crit | snapshot_handler.py:46 | Marker framed `!BIHH` (9B) but parsed as 17B `!QHH4s` → markers never recognized; Chandy-Lamport broken *(reproduced)* |
| **S5** | high | snapshot_handler.py:46-52 | Marker seq mis-parsed → never ACKed → retransmitted forever *(reproduced)* |
| **S6** | high | snapshot_handler.py:31-115 | `is_snapshotting` never reset on failure → permanent traffic black-hole |
| **S7** | high | snapshot_handler.py:136-153 | Replay uses already-advanced `recv_seq` → buffered messages silently dropped *(reproduced)* |
| **C1** | high | counter.c:192-205 | Non-atomic TRANSFER: debits then fire-and-forget CREDIT, reports OK → money destroyed on loss *(reproduced)* |
| **C2** | high | counter.c:251,184-191 | Constant `tx123` + no dedup → duplicate/retransmitted CREDIT double-counts |
| **D1** | high | tests/test_local_b.sh + mesh_proxy.py | The headline test's "RUDP saves the credit" premise fails: dead peer → route EXTERNAL → credit dropped, no retry |
| **M2** | high | mesh_proxy.py:231→urlopen | Synchronous 30s HTTP checkpoint call blocks the entire asyncio event loop |
| **M6** | high | mesh_proxy.py:193-208 | Probe timeout pins peer EXTERNAL; EXTERNAL packets are never retransmitted |
| **M13** | high | mesh_proxy.py:150 / entrypoint.sh:17 | Proxy ignores the `MESH_SUBNET` env var (uses hardcoded config) → iptables scope vs proxy classification diverge |
| **M14** | high | mesh_proxy.py:229,272 | `create_task` results not retained → retransmit loop / probes can be GC'd mid-flight |
| **B1** | high | Containerfile:9 | Images `COPY src/counter` but nothing compiles it (gitignored, absent) → build fails |
| **B2** | high | Containerfile | Host-built (macOS/arm64) binary won't exec in the Linux container ("exec format error") |
| **SEC1** | high | mesh_proxy.py tunnel | RUDP tunnel has no auth/integrity → remote packet/seq/marker injection |
| **SEC2** | high | counter.c node() | App trusts any UDP source: anyone can RESET/mint/transfer *(reproduced)* |

## Full index by component

- `01-counter-app.md` — **C1**–**C10** (the migrated workload). Memory-safety verified clean (C8).
- `02-mesh-proxy.md` — **M1**–**M14** (RUDP/TPROXY sidecar).
- `03-snapshot-handler.md` — **S1**–**S11** (Chandy-Lamport + CRIU trigger). Most broken module.
- `04-distributed-correctness.md` — **D1**–**D6** (end-to-end migration invariant).
- `05-shell-and-build.md` — **B1**–**B13** (scripts, Containerfiles, reproducibility).
- `06-entrypoint-iptables.md` — **N1**–**N7** (TPROXY plumbing + config).
- `07-aux-tools.md` — **A1**–**A8** (redis_client.py, tcp-howto.c, chat.py, udp_script.py).
- `08-security.md` — **SEC1**–**SEC6**.
- `_workflow_raw.md` / `_workflow_raw.json` — unedited 100-agent output (102 items) for traceability.
- `_completeness_critic.md` — the gap-pass driver notes.

## Severity counts (curated)
- critical: 3 (S1, S2, S4)
- high: ~20 (S5, S6, S7, M2, M6, M13, M14, C1, C2, D1, B1, B2, SEC1, SEC2, + A1, N6, M1, M10, …)
- medium: ~25
- low/info: ~22 (incl. verified-safe negative results: C8, A6, D6, N5)

## Reproduced at runtime (see `repros/output/`)
S1, S2, S4, S5 (+S5 ACK mismatch), S7 (BugD), C1, C3 (negative-mint), SEC2 (unauth RESET).

## Cross-validation
Manual ground-truth analysis and the independent 100-agent pass agreed on every critical/
high finding (79 of 102 agent items were independently `confirmed`). The agent pass also
contributed M13, M14, the M7 fd-leak, C3b, and N7; the manual pass contributed the runtime
repros and the D-series end-to-end reasoning. A handful of agent items were judged
`false_positive` (e.g. "struct.unpack on short packet" — length checks exist) and are kept
labeled in `_workflow_raw.md`.
