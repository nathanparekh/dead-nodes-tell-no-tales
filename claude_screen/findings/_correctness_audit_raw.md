Aux tools confirmed:
- **A1**: tcp-howto.c line 121-122: `ret = inet_aton(...)` then `if (ret < 0)` — inet_aton returns 1/0, never negative, so the check never fires → holds.
- **A2**: lines 135-137 bare `write`/`read` unchecked → holds.
- **A3**: line 107 `main_cl(int argc, char **argv)` argc/argv unused → holds.
- **A5**: redis_client.py timed_get line 190 returns `Status.OK` regardless of whether `val` is None → holds (deep-dive confirms holds, LOW).

I have enough to write the audit. One key disagreement to flag: the deep-dive on **S10** claims `recording_channels` is initialized at line 40 "before markers broadcast at line 43-52" — confirmed in the actual code, so S10's "ordering violates Chandy-Lamport" is correctly downgraded to overstated. And **M14** deep-dive (false_positive, Python 3.11) is consistent with Containerfile.app `python:3.11-slim`, but note the actual sidecar (Containerfile.rudp) uses `python:3.11-alpine` — still 3.11, so the refutation holds.

Here is the final report.

---

# CORRECTNESS AUDIT — Adversarial Re-Review

Scope: counter.py (deployed app), proxy/ (mesh_proxy.py, snapshot_handler.py, config.py, entrypoint.sh), shell/build harness, aux tools. All findings re-checked against current code on branch `bug-hunt-claude-screen`. Where the per-file audit and the targeted deep-dives disagree, I read the code and give a single call.

## 1. Verdict counts

Counting distinct findings (the 09-merge-impact echoes of C/B/SEC/M/S/D are duplicates of the originals and not double-counted; CP1/CP2 are new):

| Verdict | Count | IDs |
|---|---|---|
| **Holds (real)** | ~46 | C1, C2(see §3), C3, C3b, C5, C6, C7, C9, C10, CP1, CP2, SEC1, SEC2, M1, M2, M3, M4, M5, M6, M7, M10, M11, M13, S1, S2, S3, S4, S5, S6, S7, S8, S11, D4, D5, D6, B4, B5, B9, B10, B11, B12, A1–A7, A8, N5, N6, SEC5, SEC6 |
| **Overstated** (real, wrong severity/scope) | 9 | C2, M8(audit) , M9, M12, S9(see §3), S10, D2, N1, SEC4, B13 |
| **False positive** (not a real bug) | 6 | M8(deep-dive), M14, N7, B1, B2, B3 |
| **Obsolete after merge** (referenced deleted files; did NOT migrate) | 4 | C4, C8, B7, B8 |
| **Cannot determine / topology-dependent** | 2 | D1, SEC3, D3(split) |

Roughly **80% of distinct findings hold as written**; another ~10% are real-but-overstated; only ~6 are genuine false positives and ~4 are cleanly obsolete.

## 2. False positives (NOT real bugs)

- **B1** "Images COPY a prebuilt `src/counter` binary" — REFUTED. `Containerfile.counter:7` is `COPY src/counter.py .` and `Containerfile.test:18` is `COPY src/counter.py .`. The deployed artifact is Python source, which exists. (Stale comment `Containerfile.test:17` still says "compiled C counter app" — cosmetic only.)
- **B2** "Cross-arch host-built binary won't exec in Linux container" — REFUTED. Same reason as B1: only `.py` source is copied; no compiled artifact, no arch dependency.
- **B3** "`udp-counter` image-name collision" — REFUTED. Root `build.sh:12-13` builds `counter` and `sidecar`. `proxy/build.sh:3` builds `udp-counter`. No name collides between the two scripts.
- **M8** "Startup race: MESH/marker sends before `tunnel_transport` set" — REFUTED (deep-dive call; I concur over the per-file "overstated"). MESH state (`mesh_proxy.py:297`) requires a prior PROBE_ACK, and peers (`get_peer`, line 152-154) are only created from `datagram_received`, both of which require `connection_made` (line 32-33) to have already set `tunnel_transport`. At startup `peers` is empty so the marker loop (`snapshot_handler.py:43-52`) never runs. Net: nit.
- **M14** "`create_task` results not retained → GC'd mid-flight" — REFUTED. Runtime is Python 3.11 (`Containerfile.rudp:1` alpine, `Containerfile.app:1` slim, both 3.11). The bpo-41001 GC window was fixed in 3.7.2+; `_retransmit_loop` (line 229) is an infinite task held by the loop scheduler, and `_probe_target` (line 272) is short-lived. Storing refs is still good practice (no cancel handle), but no defect.
- **N7** "TPROXY hairpin may not intercept locally-originated packets" — REFUTED to low/likely-working. The whole D1 analysis assumes interception *does* fire (sidecar-A receives the CREDIT via `recvmsg`/`IP_RECVORIGDSTADDR`, `mesh_proxy.py:234,249-252`). If interception failed, the app never reaches the proxy at all. Non-standard design, but no evidence of escape; correctly a "needs live tcpdump" item, not a confirmed bug.

## 3. Overstated (real, but wrong severity/scope)

- **C2** (the deep-dive sub-claim about ACK-loss double-credit) — OVERSTATED. The constant `tx123` (`counter.py:99`) and absent app-level idempotency (`counter.py:52-61`) are real. But the specific "lost ACK → double-credit via RUDP retransmit" mechanism is defeated by tunnel-level seq dedup (`mesh_proxy.py:94,120-126`): a retransmit reuses the same seq and is filtered after `recv_seq` advances. The headline C2 defect still holds; only the RUDP-replay framing is wrong. Corrected: low–medium.
- **M9** "cmsg parse lacks length validation; assumes single AF_INET record" — OVERSTATED to nit. Offsets `[2:4]`/`[4:8]` (`mesh_proxy.py:251-252`) are correct for `sockaddr_in`; the kernel guarantees a full 16-byte record for `IP_RECVORIGDSTADDR`. Missing `len()` check is defensive hardening, not a functional defect. (It does interact with M3 — if a malformed cmsg ever did raise, M3's narrow `except` would let it escape.)
- **M12** "Retransmit mutates peers while iterating; wall-clock" — OVERSTATED to nit/low. Single-threaded asyncio + no `await` in the loop body (`mesh_proxy.py:311-316`, `list()` copy on `unacked` at 312) makes the mutation concern moot. `time.time()` at line 310 is a genuine fragility, but the CRIU-time-jump trigger is unverified (ASSUMPTIONS.md: no e2e CRIU runs). Code smell.
- **S9** "`gethostname()` may target wrong container" — per-file said "holds," deep-dive escalated to **high**; I call it **holds, severity high but unreachable in the deployed test path**. `--network container:X` shares only the net namespace, not UTS, so `snapshot_handler.py:97` can return the sidecar's hostname. Real correctness bug, but only reachable through the dead Chandy-Lamport path (see C9/D5), so blast radius is theoretical today. Best call: holds; effective severity bounded by reachability.
- **S10** "Snapshot ordering doesn't match Chandy-Lamport" — OVERSTATED. I read the actual order: `is_snapshotting=True` (line 35) → app checkpoint (line 37) → `recording_channels` init (line 40) → marker broadcast (line 43-52) → channel buffering (line 79-89). That IS record-state → send-markers → record-channels. The snapshot is broken by S4–S7 (wire format, replay), but the *ordering* itself is sound. Corrected: low.
- **D2** "Two-container shared-netns checkpoint ordering unsound" — OVERSTATED. Containers aren't removed during checkpoint, and the test already restores netns-owner first (`test_local_b.sh:37` counter-b, then `:38` sidecar-b). Latent fragility / undocumented ordering dependency, not a present failure. Corrected: low.
- **N1** "Non-idempotent netns setup breaks proxy on restart" — OVERSTATED. `entrypoint.sh:15-18` are non-idempotent under `set -e` (line 2), true. But CRIU restore doesn't re-run the entrypoint, `podman start` resumes without re-running it, and `rm`+`run` gives a fresh netns. No tested path hits it. Corrected: low (real only under non-standard manual re-invocation).
- **SEC4** "Proxy will spoof ANY source IP" — OVERSTATED. Delivered source IP is `remote_ip` = the tunnel sender's actual address (`mesh_proxy.py:82,190-191`), not attacker-arbitrary. Attacker controls dest IP/port and (via no tunnel auth, SEC1) can reach the port, but "ANY source IP" is misleading. Real issue, narrower than stated.
- **B13** "cmds.sh mixes .tar.zst / .tar.gz" — OVERSTATED. Confirmed `cmds.sh:14` zst vs `:16` gz vs `:20` mixed. But `cmds.sh` is non-executing documentation (`# from prince`, no shebang); podman doesn't infer compression from extension. Doc nit only.

## 4. Obsolete after merge (referenced now-deleted files; did NOT migrate)

- **C4** "IPV6_V6ONLY on AF_INET socket" — Obsolete/FIXED. `counter.py:12-16` sets only `SO_REUSEADDR`; the C-specific bug is gone in the rewrite.
- **C8** "sscanf field widths vs buffers" — Obsolete. C buffer-overflow analysis; Python strings are dynamic. N/A to counter.py. (Was an INFO/negative finding anyway.)
- **B7** "Port 5000 vs 9000 inconsistency" — Obsolete/FIXED. The offending `test_without_proxy/build.sh` (9000) was deleted. `test/test_local_b.sh:5` and `build.sh:35` both use 5000.
- **B8** "test_without_proxy name/IP contract mismatch" — Obsolete. The entire `test_without_proxy/` directory no longer exists.

(Distinct from these: C5, C6, C7, C9, C10, SEC2 were also "C-version" findings but DID carry over into counter.py verbatim — they hold, not obsolete.)

## 5. Confirmed solid (clearly hold — including all runtime-reproduced)

Runtime-reproduced in `claude_screen/repros/output/`:

- **C1** Non-atomic TRANSFER destroys money — `counter.py:70` `counter -= amount` → `:74` fire-and-forget `send_udp()` (return value discarded) → `:77` `OK TRANSFER` regardless. `repro_counter_py.txt:6-12`: transfer 7 to dead host drops A 10→3, returns OK. **Holds.**
- **C3** Negative amount mints funds — `counter.py:68` `int(parts[4])`, no validation; `:70` accepts negatives. `repro_counter_py.txt:19-23`: transfer −5 raises 999999→1000004. **Holds.**
- **SEC2** No auth on RESET/TRANSFER/CREDIT — `counter.py:52,62,78` apply unconditionally. `repro_counter_py.txt:14-17`: unauth RESET to 999999 succeeds. **Holds.**
- **S1** `process_and_deliver` called with too few args — `snapshot_handler.py:137-139` passes 5 args; signature `mesh_proxy.py:183-184` needs 6 (`target_local_ip`). `repro_snapshot_bugs.txt:4`: `TypeError: missing 1 required positional argument: 'target_local_ip'`. **Holds.**
- **S2** recv_buffer flush unpacks 3 from a 4-tuple — `snapshot_handler.py:143` unpacks 3; `mesh_proxy.py:121-126` stores 4. `repro_snapshot_bugs.txt:6`: `ValueError: too many values to unpack (expected 3)`. **Holds.**
- **S4** Marker wire format unparseable — `snapshot_handler.py:46` packs `!BIHH` (9 bytes); `mesh_proxy.py:79-80` parses `!QHH4s` from `data[1:17]`. `repro_snapshot_bugs.txt:7`: sent_seq=7 read as 30064771072, `startswith('__MARKER__:')=False`. **Holds.**
- **S5** Marker never ACKed → retransmitted forever — `snapshot_handler.py:51` unacked key=4-byte seq vs receiver ACKs the mis-parsed 8-byte seq. `repro_snapshot_bugs.txt:8`: key=7 vs ACK 30064771072, never matches. **Holds.**
- **S7** Replay uses already-advanced `recv_seq` — `snapshot_handler.py:136` `if seq == peer.recv_seq`, but `mesh_proxy.py:103` advances `recv_seq` unconditionally at first receipt. `repro_snapshot_bugs.txt:10`: recv_seq pre-advanced to 2, replay of [0,1] delivers 0. **Holds.**

Other clearly-solid (read & confirmed):

- **S3** 3-tuple written to recv_buffer (`snapshot_handler.py:155`) vs 4-tuple expected on live flush (`mesh_proxy.py:107`). **Holds.**
- **S6** `is_snapshotting` only reset in `_finish_global_snapshot` (`:119`); `_trigger_app_snapshot_out_of_band` swallows all exceptions (`:112`), so a checkpoint-agent failure pins `is_snapshotting=True` and black-holes recording channels forever. **Holds.**
- **S8 / M2** Synchronous `urllib.request.urlopen(req, timeout=30)` (`snapshot_handler.py:109`) on the asyncio event loop (called from `datagram_received` path). **Holds.**
- **M1** recv_buffer arity inconsistency across modules (`mesh_proxy.py:121-126` 4-tuple vs `snapshot_handler.py:143-145,155` 3-tuple). **Holds.**
- **M3** Drain loop catches only `BlockingIOError` (`mesh_proxy.py:305`); S1 `TypeError`, S2 `ValueError`, M9 `struct.error` escape the `loop.add_reader` callback. Deep-dive correctly raises to **high**. **Holds.**
- **M5** Marker shares `send_seq` but different wire format vs data (`snapshot_handler.py:46` `!BIHH` vs `mesh_proxy.py:288` `!BQHH4s`). **Holds.**
- **M6** Probe timeout pins EXTERNAL; EXTERNAL packets sent once via spoof socket, not added to `unacked` (`mesh_proxy.py:200-208, 301-303`); PROBE_COOLDOWN=5.0. **Holds.**
- **M7** Spoof-socket LRU eviction + silent bind fallback drops `IP_TRANSPARENT`/`SO_REUSEPORT` (`mesh_proxy.py:163-180`; fallback at 178-179 sets only SO_MARK); `except OSError as e` with `e` unused, and the original `sock` is replaced without `close()` (fd leak). **Holds.**
- **M10** Unbounded auto-created peers from any tunnel source (`mesh_proxy.py:154` via `:40`), no tunnel auth, no cap. **Holds.**
- **M11** `import random` unused (`mesh_proxy.py:3`, grep-confirmed only line 3), `except OSError as e` `e` unused (`:174`), `flags` unused (`:234`). **Holds.**
- **M13 / N6** `MESH_SUBNET` env ignored by proxy: `mesh_proxy.py:150` uses hardcoded `config.py:11` "10.24.24.0/24", while `entrypoint.sh:17` uses `$MESH_SUBNET`. Divergence possible. **Holds.**
- **CP1** Blanket `except Exception: pass` (`counter.py:88-89`) wraps the whole `node()` loop — swallows decode/parse/send errors and busy-spins on persistent `recvfrom` errors; truncated commands (len checks at 54/64/80) get no reply. **Holds** (re-rated HIGH).
- **C5/C6/C7/C9/C10/C3b** all confirmed in counter.py at cited lines. **Hold.**
- **SEC1** Tunnel on 0.0.0.0:9001 with zero auth/integrity (`mesh_proxy.py:38-136, 221-224`). **Holds, high.**
- **SEC5** `--privileged` + host podman socket mounted (`run_test_suite.sh:19-26`). **Holds, low (necessary for CRIU).**
- **SEC6** Unauthenticated checkpoint over plain HTTP (`snapshot_handler.py:100-103`). **Holds, low.**
- **N5** PROXY_MARK=99 loop-exemption logic verified sound (`entrypoint.sh:17` `! --mark 99`; `mesh_proxy.py:171,223` set SO_MARK=99). **Holds.**
- **B4** `udp-tester` referenced (`run_recv.sh:4`, `run_send.sh:2`) but never built — `proxy/build.sh:4` builds `udp-test`, not `udp-tester`. **Holds** (note: the audit's exact image-name reasoning is slightly off — current build.sh names are `udp-counter`/`udp-test`/`rudp-sidecar` — but the mismatch is confirmed).
- **B5** `run_chat_b.sh:1` `udo podman rm -fa` (typo) + no shebang. **Holds.**
- **B9** `build.sh:11` `sudo podman rm -fa` removes all host containers. **Holds.**
- **B10** `--network vlan` referenced in many scripts (`build.sh:34`, `run_test_suite.sh:20`, `proxy/run_chat_a.sh:3`, etc.) with no `podman network create`. **Holds.**
- **B11** `run_test_suite.sh:13` backgrounds `podman system service --time=0 &` untracked, never killed. **Holds.**
- **B12** `build.sh:47` unquoted `$SIDECAR_NAME`; `entrypoint.sh:10` unquoted `$DETECTED_SUBNET`; `test/test_local_b.sh:9` `B_CONTAINER` unused; `cmds.sh` no shebang. **Holds.**
- **B6** Relocated to `run_test_suite.sh`: `--rm -it` foreground container (`:19-27`) then sidecar attach to it after removal (`:31-36`), and `$MESH_SUBNET` undefined under `set -u` (`:3,:35`); image `sidecar` (`:36`) is never built by this script. **Holds.**
- **D3 (asymmetry half)** checkpoint without `--tcp-established` (`test_local_b.sh:26-27`) vs restore with it (`:37-38`) — real asymmetry; but grep confirms zero SOCK_STREAM in deployed code, so the flag is inert. Per-file says holds, deep-dive says false-positive/nit. **My call: real asymmetry, functionally moot for UDP-only → nit.**
- **D4, D5, D6** distributed-correctness — hold as written (D5 hinges on the snapshot path being dead, confirmed by C9: counter.py never emits `__START_SNAPSHOT__`).
- **A1–A8** aux tools — all confirmed at cited lines (A1 `tcp-howto.c:121-122` inverted `inet_aton` check; A2 `:135-137` unchecked read/write; A3 `:107` unused argc; A5 `redis_client.py:190` returns OK for None; A4/A6/A7/A8 as described). **Hold.** A4/A6/A7/A8 are aux-only / low impact.

## 6. Net assessment

**The review is sound.** Against the current post-merge code, the overwhelming majority of findings reproduce exactly at the cited file:line. The 5 snapshot defects (S1, S2, S4, S5, S7) and 3 counter defects (C1, C3, SEC2) are not just static claims — they are runtime-reproduced in `repros/output/` and I confirmed the underlying lines (e.g., the 5-vs-6 arg signature mismatch between `snapshot_handler.py:137` and `mesh_proxy.py:184` is unambiguous).

Approximate breakdown of distinct findings: **~80% hold as written, ~10% are real but overstated in severity/scope, ~6 are genuine false positives, ~4 are cleanly obsolete after the merge.** That is a low false-positive rate for an audit of this size.

Where the per-file audit and deep-dives disagreed, the deep-dives are the better call on **M8** (false positive, not overstated — startup race is unreachable), **M14** (false positive on 3.11), and **N7** (likely working). The deep-dives over-corrected on **D3** (calling it false positive) where I keep it as a real-but-moot nit. On **S9** the deep-dive's "high" is the right severity in principle, but reachability is gated by the dead Chandy-Lamport path, so its practical priority is below the live-path bugs.

Two items genuinely cannot be settled from code alone: **D1** (depends on inter-machine vs intra-machine topology — TPROXY interception of same-host inter-container traffic) and **SEC3** (references M3/M4/M9/M10 that aren't in 08-security.md; the underlying unbounded-buffer and `__MARKER__:` split IndexError concerns are real, but SEC3 as a standalone item is a summary). The N7/D1 hairpin question and the M12 CRIU-time-jump trigger both need live `tcpdump`/CRIU runs that ASSUMPTIONS.md says were not performed.

Highest-priority confirmed defects to fix first: **S1/S2/S3/S4/S5/S7 + M3** (the snapshot/CRIO restore path is fully broken and will throw unhandled exceptions that abort the drain loop), then **C1/C3/SEC2/SEC1** (money destruction, minting, unauthenticated mutation, unauthenticated tunnel) for the financial-transaction threat model.