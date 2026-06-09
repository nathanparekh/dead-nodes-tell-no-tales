# Completeness critic notes (gap pass driver)

I now have enough context to identify the gaps. Let me note key observations before composing the under-examined checklist.

Key findings while surveying:
- `entrypoint.sh:17` marks packets with mark **1**, but `TPROXY --tproxy-mark 1` and `ip rule fwmark 1`. But the proxy uses `PROXY_MARK=99` to *exempt* its own outbound. The mangle OUTPUT rule excludes `--mark 99`. But the snapshot HTTP request to `host.containers.internal:9090` is NOT marked 99 — wait, it goes over TCP, and the rule only matches `-p udp`. Worth a check though.
- `entrypoint.sh:18` PREROUTING TPROXY redirects to `--on-port 9000` but only matches `-m mark --mark 1`. PREROUTING packets need to be marked first; there's no mangle PREROUTING marking rule for inbound mesh traffic — only OUTPUT marks. This means TPROXY in PREROUTING may never fire for genuinely forwarded/inbound packets. Worth flagging as under-examined.
- `redis_client.py` is entirely untouched. It's possibly a red herring / unused, but I should flag specific checks.

Now let me compose the completeness-critic output: specific additional checks to run, focused on under-examined files and missing categories.

Based on my survey, here is my completeness assessment.

## Files barely or never touched
- **`src/redis_client.py` (355 lines): ZERO prior findings.** Entirely unexamined.
- **`proxy/entrypoint.sh` iptables/routing semantics:** only idempotency flagged (#45, #56, #59); the actual TPROXY mark/route correctness is unexamined.
- **`src/Makefile`, `Containerfile.tests`, `Containerfile`, `proxy/Containerfile.app/.rudp/.test`, `test_without_proxy/Containerfile`:** only superficially examined.
- **`build.sh`, `build-without-proxy.sh`, `cmds.sh`, `run_test_suite.sh`, `tests/run_tests.sh`:** mostly untouched.
- **`src/tcp-howto.c` server side (lines 1-120, 140-152):** only client-side lines 121-140 examined.

## Missing / under-covered categories

### Byte-order, signedness, integer truncation, field-width
1. **mesh_proxy.py:251 — `struct.unpack("!H", cmsg_data[2:4])` reads the dest port from `IP_RECVORIGDSTADDR` ancillary data WITHOUT byte-swapping concerns AND assumes `sockaddr_in` layout.** Verify: cmsg_data is a `struct sockaddr_in`; bytes [0:2] are `sin_family` (host byte order on Linux, NOT network), bytes [2:4] are `sin_port` (network order — `!H` correct), [4:8] `sin_addr`. Check whether `sin_family` at [0:2] being host-order matters and whether the 4s IP slice is valid only for AF_INET. Confirm this breaks if kernel ever delivers IPv6 origdst.
2. **Port field truncation: all ports packed as `H` (16-bit) — mesh_proxy.py:59, 251, 288-294; counter ephemeral source ports.** This is correct width for ports, but verify `orig_src_port`/`peer.send_seq` interplay: confirm `send_seq` is `Q` everywhere it's packed/unpacked. **CONFIRMED INCONSISTENCY worth a dedicated check: snapshot_handler.py:46 packs seq as `I` (BIHH) while mesh_proxy.py:59 packs as `Q` (BQHH) — already flagged, but ALSO check the corresponding ACK path:** marker packets broadcast by snapshot_handler get a 17-byte... no, 7-byte header; when the receiver's TunnelProtocol.datagram_received parses msg_type==0 it requires len>=17 and unpacks `!QHH4s` — verify the seq value the receiver ACKs (`!BQ`) will NOT match the sender's `unacked` key (sender stored under `I`-packed seq value but the integer key is the same). The real bug: receiver computes a garbage seq from misaligned bytes, ACKs garbage seq, so sender's `unacked[send_seq]` never clears → infinite retransmit. **Run this trace explicitly.**
3. **counter.c:184/192 — `int amount` and `int counter`; check `sscanf %d` into `int` with values that overflow INT_MAX, and the `4s`/IPv4-only assumption is irrelevant here, but check `to_int`/`strtol` overflow → already partially flagged (#5,#6). NEW: check `sscanf("CREDIT %127s %63s %d")` — `from[64]` buffer with `%63s` is safe, `txid[128]` with `%127s` safe, but `host[256]` with `%255s` and `peer_port[32]` with `%31s` safe. HOWEVER buf is only 512 (`BUF`) and `n=recvfrom(...sizeof(buf)-1...)` — fine. Check `credit[BUF]` snprintf at counter.c:201 for truncation when txid+name+amount exceeds 512.**

### asyncio cancellation / lifecycle
4. **mesh_proxy.py:229 `asyncio.create_task(self._retransmit_loop())` and :272 `asyncio.create_task(self._probe_target(...))` — returned task objects are never stored.** Check: tasks can be garbage-collected mid-flight (Python docs warn create_task results must be retained). Flag as a real GC-cancellation bug.
5. **mesh_proxy.py:_probe_target uses `await asyncio.sleep(0.1)` as the probe timeout** — check the race where PROBE_ACK arrives AFTER the 0.1s sleep already flipped state to EXTERNAL and flushed probe_buffer directly to target (line 204-208) bypassing the mesh; then the late ACK handler (line 50) pops an already-empty buffer (fine) but state is EXTERNAL while remote believes MESH — **split-brain routing-state check.**
6. **No graceful shutdown closes `tunnel_transport`, `local_sock`, or spoof_sockets** — on KeyboardInterrupt (line 326) sockets leak; relevant to CRIU restore (stale FDs). Run an FD-lifecycle check.

### CRIU / file-descriptor restore semantics
7. **Check CRIU restore implications: after restore, `peer.send_seq`/`recv_seq` in the proxy are in-memory only (not persisted with the app checkpoint).** The proxy process is separate from the checkpointed app. Verify: does the proxy get checkpointed too? If only the counter app is checkpointed/restored on node C, the destination proxy's `recv_seq` for the source is stale/zero → **all replayed in-flight messages with seq>recv_seq get buffered forever** (snapshot_handler.py:154-155 buffers, never delivers because recv_seq never catches up). This is a core consistency check.
8. **`socket.gethostname()` (snapshot_handler.py:97) as container_id** — after CRIU restore the hostname may differ or the checkpoint agent keys by it; verify container_id stability across restore.
9. **UDP socket restore: the counter app's bound UDP socket FD and the proxy's TPROXY sockets (`IP_TRANSPARENT`, `SO_MARK`) — check whether CRIU can restore `IP_TRANSPARENT`/`SO_MARK`/`SO_REUSEPORT` sockopts; these are commonly not restored.** Flag as restore-fragility.

### TOCTOU / race windows
10. **mesh_proxy.py:256-282 — routing_table state is read (line 256) then mutated across `await` boundaries (create_task).** Between `recvmsg` iterations within one `_handle_local_intercept` call there's no await, but `_probe_target` runs concurrently and mutates `routing_table`/`probe_buffer`. Check the window: line 280 `self.probe_buffer[target_ip].append(...)` assumes PROBING-state buffer exists, but `_probe_target` may have `pop`-ed it (line 204) and set EXTERNAL — KeyError (overlaps #14 but verify this specific interleave).
11. **snapshot_handler.py:35 sets `is_snapshotting=True` BEFORE the blocking HTTP call (line 37→109).** During the 30s blocking urllib call the event loop is frozen (#25), but ALSO check: marker broadcast (line 43-52) happens AFTER the HTTP returns, so peers receive markers 30s late — Chandy-Lamport correctness: in-flight messages during those 30s on OTHER channels are NOT recorded because recording_channels is set at line 40 but the OUTPUT marking/broadcast is delayed. **Trace the Chandy-Lamport algorithm correctness end-to-end.**

### partial-read / partial-write / error paths
12. **tcp-howto.c server side (lines ~40-120, unread) — check `read()`/`write()`/`accept()` partial and error handling on the SERVER, not just client.**
13. **counter.c:202 `send_udp(host, peer_port, credit)` return value ignored** — TRANSFER debits local counter (line 196) THEN sends credit; if send_udp fails the money vanishes (debit succeeded, credit never sent). **Atomicity/durability check — money-loss bug distinct from #2.**
14. **counter.c:184 CREDIT path — if `sscanf` matches CREDIT but with a malformed amount that fails the `==3` check, falls through to TRANSFER/RESET/ERR.** Check partial-parse fall-through ambiguity (a "CREDIT" prefix that fails sscanf returns "ERR" silently to a real credit — money loss).

### Chandy-Lamport / distributed consistency (deep)
15. **snapshot_handler.py:_finish_global_snapshot delivers recorded channel state via `process_and_deliver` (line 137) — but recorded messages were ALREADY counted in the receiver's `recv_seq` advancement?** Check double-delivery: in mesh_proxy datagram_received, when `is_snapshotting`, `process_message` returns True (consumed, line 89) so recv_seq is NOT advanced for cached messages (line 94-103 only advances on delivery, and process_and_deliver→process_message returns True so... wait, recv_seq IS advanced at line 103 regardless of consumed). **Trace: does caching a message during snapshot still advance recv_seq? If yes, replay at line 136 `if seq == peer.recv_seq` never matches → replayed messages lost.** This is a critical correctness trace to run.
16. **snapshot_handler.py:40-41 — `recording_channels = set(peers.keys())` minus initiator.** Peers dict only contains nodes seen so far. A peer that has NOT yet sent anything (no PeerState) is omitted from recording → its in-flight messages unrecorded. **Membership-completeness check.**
17. **Marker only sent to existing `self.proxy.peers` (snapshot_handler.py:43).** If a channel exists in routing_table as MESH but never created a PeerState (it does via get_peer on send), check consistency between routing_table and peers as the membership source of truth.

### IPv4 / 4s assumption
18. **Every `socket.inet_aton`/`inet_ntoa`/`4s` pack (mesh_proxy.py:56,82,286; cmsg_data[4:8]) assumes IPv4.** Confirm macvlan is v4-only; flag the hard v4 assumption as a portability/correctness limit if any v6 path exists.

### Security (additional)
19. **redis_client.py: `--password` passed but check if logged/echoed.** Also check `make_client` recreation on every outage (line 320) leaks connections (no `client.close()`).
20. **entrypoint.sh:5 subnet auto-detect via `ip route | grep -v default | head -1`** — picks arbitrary first route; if the container has multiple routes the mesh subnet detection is wrong (overlaps #62, but verify it can pick the docker0/podman bridge instead of macvlan).

### Build / reproducibility (additional)
21. **src/Makefile:2 `-Werror` — given the known unchecked-return-value bugs (#2,#13), check whether `-Wall -Wextra -Werror` would actually FAIL the build** (e.g., `-Wunused-result` on sendto/write, unused variable `txid` at counter.c:249). If the committed code can't compile under its own Makefile, that's a repro-breaking bug. **Actually compile it.**
22. **Containerfile vs proxy/Containerfile.* — verify which Containerfile actually builds the counter binary and whether `src/counter` (committed binary, present in tree!) is a stale checked-in artifact** that COPY uses instead of rebuilding (reproducibility/staleness). `src/counter` exists in the file list — check if it's gitignored or committed stale.

### Concrete commands to run
- Compile under the real Makefile: `make -C src clean && make -C src` — confirm whether -Werror breaks on unused `txid`/unchecked returns.
- `git ls-files src/counter` — is the binary committed (stale-artifact bug)?
- `python -m py_compile proxy/snapshot_handler.py proxy/mesh_proxy.py src/redis_client.py` and trace the recv_seq advancement interaction described in #15 by reading lines 94-103 vs 136 together.
- Grep for `create_task` retention, `client.close`, `.close()` on sockets, and any `await` between routing_table read and write.
- Read tcp-howto.c server half (lines 1-120) and the unread Containerfiles (`Containerfile`, `Containerfile.tests`, `proxy/Containerfile.app/.rudp/.test`, `test_without_proxy/Containerfile`), `build.sh`, `build-without-proxy.sh`, `cmds.sh`, `run_test_suite.sh`, `tests/run_tests.sh` in full.

### Highest-priority NEW leads not yet in the findings list
- **A. counter.c:196+202 — debit-without-credit money loss when send_udp fails (unchecked return).** Distinct atomicity bug.
- **B. snapshot_handler.py recv_seq double-advance vs replay-never-matches — replayed in-flight messages permanently dropped after a snapshot (Chandy-Lamport replay broken).** Trace lines 94-103 vs 136-155.
- **C. CRIU restore drops proxy seq-state: restored node's peer proxy has stale recv_seq → all post-restore packets buffered forever.** Core migration-correctness gap.
- **D. asyncio create_task results not retained (mesh_proxy.py:229,272) — tasks may be GC'd.**
- **E. entrypoint.sh PREROUTING TPROXY rule matches `--mark 1` but nothing marks inbound packets in PREROUTING — TPROXY interception of forwarded traffic may never fire.**
- **F. Marker-packet seq misalignment (`I` vs `Q`) causes receiver to ACK a garbage seq → sender unacked never clears → infinite marker retransmit storm.** Trace the ACK-key match explicitly.
- **G. src/counter is a committed/stale binary artifact; Makefile -Werror likely fails to compile the committed source (unused `txid`, unchecked-result warnings) — repro-breaking.**
- **H. mesh_proxy.py:320-331 no socket cleanup on shutdown; IP_TRANSPARENT/SO_MARK/SO_REUSEPORT sockopts likely not CRIU-restorable — restore fragility.**
- **I. redis_client.py:320 recreates client every outage without closing the old one — connection/FD leak (entirely unexamined file).**