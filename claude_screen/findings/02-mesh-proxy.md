# Findings — `proxy/mesh_proxy.py` (+ `proxy/config.py`)

The transparent TPROXY/RUDP mesh sidecar. Static tools can't see most of these because
`SnapshotController.proxy`/cross-module calls are untyped (pyflakes/pylint/mypy output in
`analysis_output/31..37`).

---

## M1 — `recv_buffer` tuple arity is inconsistent across modules  [HIGH, confidence high — reproduced]
**Where:** stored as a **4-tuple** `(payload, src_port, dst_port, exact_local_ip)` at
`mesh_proxy.py:121` and unpacked as 4 at `:107`; but `snapshot_handler.py` produces and
consumes **3-tuples** (`:143-145`, `:155`).
**Why it's a bug:** Whenever the snapshot flush touches a buffer entry written by
`TunnelProtocol` (or vice-versa), the unpack throws `ValueError`. See S2/S3 for the
snapshot side. **Reproduced:** `repros/repro_snapshot_bugs.py` → `BugB`
(`ValueError: too many values to unpack (expected 3)`).
**Fix:** Use one record type (namedtuple/dataclass) for `recv_buffer` everywhere.

## M2 — Blocking, synchronous HTTP call on the asyncio event loop  [HIGH, confidence high]
**Where:** `_handle_local_intercept` (a `loop.add_reader` callback, `:231`) →
`snapshot_ctrl.process_message` → `snapshot_handler._trigger_app_snapshot_out_of_band`
→ `urllib.request.urlopen(req, timeout=30)`.
**Why it's a bug:** `add_reader` callbacks run **on the event loop thread**. A synchronous
`urlopen` with a 30s timeout freezes the *entire* proxy — no forwarding, no ACKs, no
retransmits — for up to 30 seconds. During a checkpoint (precisely when timing matters)
the data plane stalls.
**Fix:** `await loop.run_in_executor(...)` or an async HTTP client; never block the loop.

## M3 — Only `BlockingIOError` is caught in the intercept drain loop  [MEDIUM, confidence high]
**Where:** `_handle_local_intercept` `try/except BlockingIOError` (`:232`,`:305-306`).
**Why it's a bug:** Any other exception (a `struct.error` from a malformed cmsg, a
`KeyError`, or the `TypeError`/`ValueError` from the snapshot bugs) escapes the callback to
the loop's default exception handler and **aborts the current drain**, leaving queued
datagrams unprocessed for that wakeup. A crafted packet can repeatedly trip this.
**Fix:** Catch+log per-datagram; only `BlockingIOError` should break the drain loop.

## M4 — Head-of-line blocking + unbounded buffers (permanent stall / memory growth)  [MEDIUM, confidence high]
**Where:** strict in-order gate `if seq == peer.recv_seq` (`:94`); `recv_buffer`,
`probe_buffer`, `unacked`, `peers`, `routing_table` are never bounded or GC'd.
**Why it's a bug:** If one sequence number is never delivered, **all** later packets are
buffered forever and never delivered (HOL block), and the buffer grows without limit. The
marker bug (S4/S5) *guarantees* a lost seq slot whenever a snapshot is attempted, so a
single snapshot can wedge the data plane permanently. No idle-peer eviction → long-lived
proxies leak.
**Fix:** Bound buffers, add a gap-timeout/SACK or drop policy, GC idle peers.

## M5 — Marker shares the data `send_seq` space but uses a different (broken) wire format  [MEDIUM, confidence high]
**Where:** marker broadcast increments `peer_state.send_seq` (`snapshot_handler.py:46-52`)
while data uses the same counter (`mesh_proxy.py:299`).
**Why it's a bug:** Even ignoring the format bug (S4), inserting a marker into the data
sequence stream means the receiver expects that seq to be deliverable data; a malformed
marker at seq N stalls in-order progress (feeds M4).
**Fix:** Use a separate control channel / message type that does not consume the data seq.

## M6 — Probe timeout → peer pinned `EXTERNAL`; EXTERNAL packets are never retried  [HIGH, confidence high]
**Where:** `_probe_target` waits only `await asyncio.sleep(0.1)` then sets `EXTERNAL`
(`:198-202`); EXTERNAL packets are sent once via a spoof socket (`:301-303`, `:207-208`)
and are **not** added to `unacked` (only MESH packets are, `:298`). `PROBE_COOLDOWN = 5.0`
keeps the peer EXTERNAL for 5s before any re-probe (`:259-262`).
**Why it's a bug:** If the destination's sidecar is momentarily unreachable (e.g. it was
just removed for migration — the exact test scenario), the probe fails, the route becomes
EXTERNAL, the packet is sent raw to a down host and **lost with no retransmission**, and
the peer stays EXTERNAL for 5s. This defeats the proxy's entire "buffer & retry across
migration" purpose. Directly causes D1.
**Fix:** Buffer+retry for in-mesh destinations even when a probe fails; shorten/retry the
probe; don't fall back to fire-and-forget for mesh peers.

## M7 — Spoof-socket LRU eviction + silent bind fallback break source spoofing  [LOW–MEDIUM, confidence medium]
**Where:** `get_spoof_sock` LRU `popitem`+`close` at `MAX_SPOOF_SOCKETS=512` (`:163-165`);
bind-fallback on `OSError` (`:172-179`).
**Why it's a bug:** (a) Eviction closes a spoof socket that an ongoing flow still needs;
the next packet rebinds (works) but with >512 concurrent spoofed flows this churns and
can reorder. (b) The fallback path creates a **plain** socket without `IP_TRANSPARENT`/
`SO_REUSEPORT`, so the delivered packet's source is the proxy's own ephemeral address, not
the spoofed peer — the receiving app then sees the wrong source and its replies are
misrouted, silently breaking the connection illusion. The fallback is only logged, never
surfaced.
**Fix:** Make the spoof-socket pool keyed/refcounted; treat a transparent-bind failure as
a hard error, not a silent degradation.
**Addendum (fd leak):** On the bind-fallback path the *original* `sock` (already created at
`:167`) is overwritten by a new socket at `:178` **without being closed** → a file
descriptor leaks on every bind failure. (Confirmed by the workflow's netcfg pass.) Close
the original before reassigning.

## M8 — Startup race: MESH/marker sends before `tunnel_transport` is set  [LOW, confidence medium]
**Where:** `start()` registers the local reader (`:219`) **before** the tunnel datagram
endpoint is created (`:226`); `tunnel_transport` is assigned in `connection_made`.
**Why it's a bug:** A packet intercepted in that window that hits the MESH branch
(`:297`) or a marker broadcast (`snapshot_handler.py:48`) calls `self.tunnel_transport`
which is still `None` → `AttributeError`. The PROBING branch guards with
`if self.tunnel_transport` (`:195`) but MESH/marker do not.
**Fix:** Create the tunnel endpoint before adding the local reader, or guard all sends.

## M9 — cmsg parse lacks length validation; assumes single AF_INET ancillary record  [LOW, confidence medium]
**Where:** `_handle_local_intercept` ancillary-data loop `:249-253`
(`struct.unpack("!H", cmsg_data[2:4])`, `inet_ntoa(cmsg_data[4:8])`).
**Why it's a bug:** No check that `cmsg_data` is long enough; a short/truncated or
unexpected ancillary record raises `struct.error`/`ValueError`, which (per M3) escapes the
callback. Family field is assumed AF_INET without checking offset 0-2.
**Fix:** Validate `len(cmsg_data) >= 8` and the family before unpacking.

## M10 — Memory exhaustion via auto-created peers from arbitrary tunnel sources  [MEDIUM, confidence medium — see also SEC]
**Where:** `get_peer` auto-creates a `PeerState` for any source IP that sends to the
tunnel (`:152-155`), called from `TunnelProtocol.datagram_received` (`:40`).
**Why it's a bug:** A remote sender (no auth on the tunnel — SEC1) can spoof many source
IPs and force unbounded `peers`/`routing_table` growth.
**Fix:** Authenticate tunnel peers; cap/evict peer table.

## M11 — Dead/unused code  [LOW, confidence high]
`import random` unused (`:3`); unused `e` (`:174`) and `flags` (`:234`). Confirmed by
pyflakes/pylint/vulture (`analysis_output/31_pyflakes.txt`, `34`, `37`). Cosmetic but
signals the retransmit/error paths are under-exercised.

## M13 — The `MESH_SUBNET` env var is ignored by the proxy (uses hardcoded `config.py`)  [HIGH, confidence high]
**Where:** `entrypoint.sh` auto-detects/exports `MESH_SUBNET` (`:4-11`) and `build.sh:46`
passes `-e MESH_SUBNET=...`, and the **iptables** rules use `$MESH_SUBNET` (`entrypoint.sh:17`).
But `mesh_proxy.py` gets `MESH_SUBNET` from `from config import *` (hardcoded
`"10.24.24.0/24"`, `config.py:11`) and **never reads `os.environ`** — `self.mesh_network`
is built from the config constant (`:150`).
**Why it's a bug:** The data-plane interception scope (iptables, env-driven) and the
proxy's mesh-membership decision (`ipaddress.ip_address(target) in self.mesh_network`,
`:263`) are configured from **two different sources**. If the env/auto-detected subnet ever
differs from `10.24.24.0/24` (e.g. a different deployment, or entrypoint's auto-detection
picking another CIDR — N2), iptables will TPROXY traffic the proxy then classifies as
`EXTERNAL` (or vice-versa) → misrouting/black-holing. The careful env plumbing is silently
dead for the Python side.
**Fix:** Read `MESH_SUBNET` from the environment in `config.py`/`mesh_proxy.py`
(`os.environ.get("MESH_SUBNET", "10.24.24.0/24")`).

## M14 — `asyncio.create_task(...)` results are not retained → tasks may be GC'd mid-flight  [HIGH, confidence high]
**Where:** `:229` `asyncio.create_task(self._retransmit_loop())` and `:272`
`asyncio.create_task(self._probe_target(target_ip))` — neither return value is stored.
**Why it's a bug:** CPython keeps only a **weak** reference to tasks; the docs explicitly
warn to keep a strong reference or "the task may be garbage-collected at any time, even
before it's done." The retransmit loop (the entire reliability mechanism) and in-flight
probes can therefore be collected and silently stop. This is intermittent and
load/GC-dependent, which makes it nasty to debug.
**Fix:** Store tasks in a set on the proxy (`self._tasks.add(t); t.add_done_callback(self._tasks.discard)`).

## M12 — Retransmit loop mutates `unacked` while iterating; uses wall-clock  [LOW, confidence medium]
**Where:** `_retransmit_loop` `:308-317`.
**What:** Iterates `list(peer.unacked.items())` (safe copy) but reinserts under the same
key (fine); however it also iterates `self.peers.items()` without a copy while
`datagram_received`/`get_peer` can add peers — in single-threaded asyncio the loop body has
no `await`, so it's atomic per tick (OK), but a peer added mid-tick is simply missed until
next tick. Uses `time.time()` (wall clock) for timeouts, so a clock step (or CRIU restore
with a time jump) can cause a retransmit storm or stall.
**Fix:** Use `loop.time()`/monotonic clock; document the tick semantics.
