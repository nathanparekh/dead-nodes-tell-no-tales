# Correctness audit — which findings are NOT real bugs

A third pass adversarially re-checked **every** finding against the **current** (post-merge)
code, trying to *refute* each one. Method: per-file skeptics (one per `0X-*.md`) + targeted
deep-dive refuters on the 14 highest-doubt items + synthesis. Raw output:
`_correctness_audit_raw.json` / `_correctness_audit_raw.md`. My own independent re-derivation
agreed with the workflow on all items below; where the per-file pass and the deep-dive
disagreed, the deep-dive (which read the exact code path) is the call.

## Bottom line
**The review holds up.** Of the distinct findings: **~80% hold as written** (including all 8
runtime-reproduced ones), **~10% are real but overstated**, **6 are genuine false positives**,
and **4 are obsolete after the merge**. Low false-positive rate for an audit this size.

---

## A. Genuine false positives (NOT real bugs — independent of the merge)

| ID | Claim | Why it's not a bug |
|----|-------|--------------------|
| **M8** | Startup race: MESH/marker send before `tunnel_transport` is set | **Unreachable.** The MESH branch (`mesh_proxy.py:297`) needs a prior `PROBE_ACK`, and the marker broadcast (`snapshot_handler.py:43-52`) needs existing `peers`; both require `datagram_received`→`connection_made` (`:32-33`) to have already set `tunnel_transport`. At startup `peers` is empty and no route is MESH, so the null-deref can't occur. `_probe_target` is explicitly guarded (`:195`). |
| **M14** | `create_task` results not retained → tasks GC'd mid-flight | **Not on Python 3.11** (both Containerfiles pin 3.11). The premature-GC window was closed in 3.7.2+; `_retransmit_loop` is an infinite task held by the scheduler and `_probe_target` is short-lived. Keeping a handle is good practice (for cancellation) but there is no defect. |
| **N7** | TPROXY hairpin may not intercept locally-originated packets | **No evidence of escape; likely works.** The rest of the analysis (D1) assumes interception *does* fire (sidecar receives via `recvmsg`/`IP_RECVORIGDSTADDR`). It's a non-standard pattern that warrants a live `tcpdump`, but there's nothing in the code proving it fails — correctly a "verify on a node" item, not a confirmed bug. |

## B. Real but OVERSTATED (correct the severity/scope, don't delete)

| ID | Original | Corrected |
|----|----------|-----------|
| **C2** | the *"lost-ACK → double-credit via RUDP retransmit"* mechanism | The headline (constant `tx123` + no app-level idempotency, `counter.py:99,52-61`) **holds**, but the RUDP-replay path is **defeated by tunnel seq-dedup** (`mesh_proxy.py:94,120-126`): a retransmit reuses the seq and is dropped once `recv_seq` advances. Double-credit is only reachable **across migration / the EXTERNAL fallback**, not via ordinary retransmit. → low–medium |
| **M9** | cmsg parse "bug" | Offsets `[2:4]`=port, `[4:8]`=addr are **correct** for `sockaddr_in`; the kernel always supplies the full record. Only the *missing length-check* is valid → **low nit** (matters only in combination with M3). |
| **M12** | "mutates `unacked` while iterating" | It iterates a `list()` **copy** (`:312`) and the body has no `await`, so the mutation concern is **wrong**. Only the `time.time()` wall-clock fragility is valid → **low/code-smell**. |
| **S9** | `gethostname()` targets wrong container | **Holds** (only the net namespace is shared via `--network container:`, not UTS), but it's reachable **only through the dead Chandy-Lamport path** (C9), so effective priority is low despite high in-principle severity. |
| **S10** | "snapshot ordering violates Chandy-Lamport" | **Overstated.** The actual order is record-state(checkpoint, `:37`) → init recording (`:40`) → broadcast markers (`:43-52`) → record channels (`:79-89`), which *is* the correct C-L order. The snapshot is broken by **S4–S7**, not by ordering → **low**. |
| **D2** | shared-netns checkpoint ordering "unsound" | Containers aren't removed during checkpoint, and restore already does owner-first (`test/test_local_b.sh:37` then `:38`). **Latent/undocumented fragility, not a present failure** → low. |
| **N1** | non-idempotent netns setup "breaks proxy on restart" | Real under `set -e` (`entrypoint.sh:2,15-18`) **only** on a non-standard manual re-invocation over a persistent netns; CRIU restore and `podman start` don't re-run the entrypoint, and `rm`+`run` is a fresh netns → **low**. |
| **SEC4** | "proxy will spoof ANY source IP" | The delivered source is `remote_ip` = the **tunnel sender's actual address** (`:82,190-191`), not attacker-arbitrary. The attacker controls dest IP/port and (via SEC1) can reach the port. Real, but **narrower** than "any source." |
| **B13** | `cmds.sh` mixes `.tar.zst`/`.tar.gz` | `cmds.sh` is non-executing documentation; podman doesn't infer compression from the extension → **doc nit**. |
| **D3** | checkpoint omits `--tcp-established` | Real asymmetry vs restore, but **zero `SOCK_STREAM` in the deployed code** → functionally **moot for the UDP-only path** (nit). |

## C. Obsolete after the merge (were about now-deleted/rewritten code)

| ID | Status |
|----|--------|
| **C4** (`IPV6_V6ONLY` on AF_INET) | **Fixed** — `counter.py:12-16` sets only `SO_REUSEADDR`. |
| **C8** (sscanf widths) | **N/A** — was a C buffer analysis (and already a negative result); Python strings are dynamic. |
| **B7** (port 5000 vs 9000) | **Fixed** — the offending `test_without_proxy/build.sh` was deleted; everything uses 5000. |
| **B8** (name/IP contract) | **Obsolete** — `test_without_proxy/` no longer exists. |
| **B1/B2/B3** | Already recorded as fixed/obsolete in `09-merge-impact.md` (prebuilt-binary COPY, cross-arch, image-name collision) — confirmed by this audit. |

## D. Confirmed solid — the core stands (all runtime-reproduced + the rest)

Runtime-reproduced (`repros/output/`): **C1, C3, SEC2** (counter.py: money destroyed, negative-mint, unauth RESET) and **S1, S2, S4, S5, S7** (snapshot: TypeError, ValueError, marker wire-format, never-ACKed, replay-drop). The signature mismatch behind S1 (`snapshot_handler.py:137` passes 5 args; `mesh_proxy.py:183-184` needs 6) is unambiguous.

Also confirmed by reading current code: **S3, S6, S8/M2, M1, M3** (raised to **high** — S1/S2/M9 exceptions escape the `BlockingIOError`-only drain loop), **M5, M6, M7, M10, M11, M13/N6, CP1** (raised to **high**), **CP2, C5, C6, C7, C9, C10, C3b, SEC1, SEC5, SEC6, N5, B4, B5, B6** (relocated to `run_test_suite.sh`), **B9, B10, B11, B12, D4, D5, D6, A1–A8**.

## E. Two items that genuinely can't be settled from code alone
- **D1** — the *conclusion* (the test's "RUDP saves the credit" premise fails because A has no MESH route to a removed peer at transfer time → EXTERNAL → no retransmit) is robust; but the exact drop mechanism depends on whether TPROXY intercepts same-host inter-container traffic (the N7 question) vs the multi-AWS-host topology. Either way the credit is lost; needs a live run to pin the mechanism.
- **SEC3** — a roll-up of M3/M4/M9/M10; the underlying unbounded-buffer / malformed-packet concerns are real, but as a standalone "crash/DoS" item it's a summary, not a separate defect.

## Fix priority (unchanged by this audit)
1. **S1, S2, S3, S4, S5, S7 + M3** — the snapshot/restore path is fully broken and throws unhandled exceptions that abort the proxy's drain loop.
2. **C1, C3, SEC2, SEC1** — money destruction, minting, unauthenticated mutation, unauthenticated tunnel (the financial threat model).
