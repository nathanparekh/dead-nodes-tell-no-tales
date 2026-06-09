# Findings — `proxy/snapshot_handler.py` (Chandy-Lamport snapshot + CRIU trigger)

This module is the most broken in the repo. Four independent defects each make the global
snapshot crash or silently lose data. All four are **reproduced** at runtime in
`repros/repro_snapshot_bugs.py` (output in `repros/output/repro_snapshot_bugs.txt`).
Note C9: nothing currently *triggers* this path, so these are latent until the snapshot
feature is actually wired up — but every one is a real defect.

---

## S1 — `process_and_deliver` called with too few arguments → `TypeError`  [CRITICAL, confidence high — reproduced]
**Where:** `_finish_global_snapshot` calls `self.proxy.process_and_deliver(seq, payload,
remote_ip, src_port, dst_port)` at `:137-139` and `:146-152` — **5 positional args**.
The method is defined `process_and_deliver(self, current_seq, p, ip, src_port, dst_port,
target_local_ip)` (`mesh_proxy.py:183`) — it needs **6**.
**Why it's a bug:** Every snapshot that has any buffered message crashes the moment it
flushes. The delivery also can't know where to send (`target_local_ip` missing).
**Reproduced:** `BugA` → `TypeError: MeshProxy.process_and_deliver() missing 1 required
positional argument: 'target_local_ip'`.
**Fix:** Thread `target_local_ip` (the recorded destination) through `channel_states` and
pass it; pylint/mypy can't catch this because `self.proxy` is untyped — add a type hint.

## S2 — `recv_buffer` flush unpacks 3 values from a 4-tuple → `ValueError`  [CRITICAL, confidence high — reproduced]
**Where:** `_finish_global_snapshot` `next_payload, next_src_port, next_dst_port =
peer.recv_buffer.pop(...)` at `:143-145`, but `recv_buffer` entries are 4-tuples
(`mesh_proxy.py:121`). See M1.
**Reproduced:** `BugB` → `ValueError: too many values to unpack (expected 3)`.
**Fix:** Unpack 4 (or use a record type shared with mesh_proxy).

## S3 — Snapshot writes a 3-tuple into `recv_buffer`, poisoning the live path  [HIGH, confidence high]
**Where:** `_finish_global_snapshot` `peer.recv_buffer[seq] = (payload, src_port,
dst_port)` at `:155` — a 3-tuple, whereas `TunnelProtocol` later flushes it expecting a
4-tuple (`mesh_proxy.py:107`).
**Why it's a bug:** Even if S1/S2 were fixed, the snapshot leaves a malformed entry that
makes the *next* live in-order flush throw `ValueError`.
**Fix:** Write the same 4-tuple shape everywhere.

## S4 — Broadcast MARKER wire-format is unparseable; receivers never recognize markers  [CRITICAL, confidence high — reproduced]
**Where:** marker sent as `struct.pack("!BIHH", 0, peer_state.send_seq, 0, 0) + payload`
(`:46`) — a **9-byte** header with a 4-byte (`I`) seq. Receivers see `msg_type==0` and
parse a **17-byte** header `"!QHH4s"` then take `payload = data[17:]`
(`mesh_proxy.py:74-87`).
**Why it's a bug:** The 17-byte slice eats into the marker text, so on the receiving node
`payload.startswith(b"__MARKER__:")` is **False** — the marker is delivered as ordinary
(corrupted) data and the snapshot algorithm never advances. Cross-node Chandy-Lamport is
fundamentally broken.
**Reproduced:** `BugC` → parser read `seq=30064771072` (= 7≪32, i.e. the 4-byte field read
as 8 bytes), recovered payload `b'__:123e4567-...'`, `startswith=False`.
**Fix:** Use the identical 17-byte `"!BQHH4s"` framing for markers (or a dedicated control
message type with its own length check).

## S5 — Marker is never ACKed → retransmitted forever  [HIGH, confidence high — reproduced]
**Where:** sender stores `unacked[send_seq]` with the 4-byte seq (`:51`); receiver ACKs the
8-byte seq it mis-parsed (`mesh_proxy.py:90-91`).
**Why it's a bug:** The ACK seq never matches the `unacked` key, so the retransmit loop
(`mesh_proxy.py:308-317`) resends the malformed marker indefinitely, wasting bandwidth and
keeping a permanent gap in the seq space (feeds M4 HOL-block).
**Reproduced:** `BugC2` → `unacked key=7`, receiver would ACK `seq=30064771072`.
**Fix:** Fix the framing (S4) so seqs round-trip, and ACK the same seq the sender tracks.

## S6 — `is_snapshotting` never reset on failure → permanent traffic black-hole  [HIGH, confidence high]
**Where:** set True at `:35`; only reset in `_finish_global_snapshot` (`:119`). The HTTP
trigger swallows all errors (`except Exception`, `:112`) and there's no checkpoint-failure
path that resets state; if peers never echo the (broken) marker, `recording_channels`
never empties and `_finish_global_snapshot` never runs.
**Why it's a bug:** After one snapshot *attempt* (e.g. the agent at :9090 is absent — it is
absent in this repo), `is_snapshotting` stays True, so every later in-flight message on a
recording channel is cached (`:79-89`) and **never delivered** — the proxy silently
black-holes mesh traffic from then on.
**Fix:** Reset snapshot state on trigger failure and add a snapshot timeout/abort.

## S7 — Replay uses `peer.recv_seq` which is already advanced → buffered messages dropped  [HIGH, confidence high — reproduced]
**Where:** `_finish_global_snapshot` replays with `if seq == peer.recv_seq` (`:136`). But
`TunnelProtocol` increments `recv_seq` when it first *receives* a message, even if the
snapshot then caches it instead of delivering (`mesh_proxy.py:94-103` runs the increment
regardless).
**Why it's a bug:** At replay, the recorded seqs are `< recv_seq`, so neither `==` nor `>`
matches and the messages are **silently dropped**. The whole point of recording channel
state (so no message is lost across the cut) fails even absent the crashes.
**Reproduced:** `BugD` → with `recv_seq` pre-advanced to 2, replay of seqs [0,1] delivered
0 messages.
**Fix:** Don't advance `recv_seq` for messages diverted into the snapshot buffer; replay
in recorded order independent of the live counter.

## S8 — Synchronous `urllib` checkpoint POST blocks the event loop  [HIGH, confidence high]
Root cause of M2; recorded here because the call lives in
`_trigger_app_snapshot_out_of_band` (`:105-115`), `timeout=30`. Fix: async/executor.

## S9 — `container_id = socket.gethostname()` may target the wrong container  [MEDIUM, confidence medium]
**Where:** `:97`. The sidecar shares the app's **network** namespace (`--network
container:`), not necessarily its UTS/hostname, so `gethostname()` returns the *sidecar's*
identity. The host checkpoint agent would then checkpoint the sidecar/itself rather than
the app container it's supposed to snapshot.
**Fix:** Pass the app container id explicitly (env var) rather than inferring it.

## S10 — Snapshot ordering doesn't match Chandy-Lamport  [MEDIUM, confidence medium]
**Where:** initiator path (`mesh_proxy.py:236-242` → `process_message` with
`remote_ip="127.0.0.1"`): it triggers the **local app checkpoint immediately** (`:37`)
and only then records channels / broadcasts markers. Chandy-Lamport requires recording the
process state and *then* recording incoming channel state until each peer's marker
arrives; here the checkpoint precedes channel recording and (per S4-S7) the channel record
is never correctly completed → the global snapshot is not a consistent cut.
**Fix:** Record local state, emit markers, then record per-channel until markers return,
with correct framing and replay.

## S11 — Dead import + typo  [LOW]
`import os` unused (`:3`, confirmed by pyflakes/vulture); log typo "Failed to reac
Checkpoint" (`:114`).
