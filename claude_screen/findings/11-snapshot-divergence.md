# Root cause — snapshot_handler.py drifted from mesh_proxy.py (and the port to fix it)

**Question:** are there changes to `mesh_proxy.py` that should also be applied to
`snapshot_handler.py`? **Answer: yes — three of them, and they are the exact root cause of
S1–S5.**

## What the history shows
- `proxy/snapshot_handler.py` was **last edited at `e470fd7 "handoff"` (2026-06-07)** and is
  **byte-identical today** (`git diff e470fd7 HEAD -- proxy/snapshot_handler.py` is empty).
- At that moment the matching `mesh_proxy.py` was `371617b "more fixes"`, and the two were
  **in sync**:
  - `process_and_deliver(self, current_seq, p, ip, src_port, dst_port)` — **5 args** ⇄
    snapshot_handler calls it with 5 args ✓
  - `recv_buffer = {seq: (payload, orig_src_port, orig_dst_port)}` — **3-tuple** ⇄
    snapshot_handler reads/writes 3-tuples ✓
  - packet header `!BIHH` (type+`I`(4-byte seq)+srcport+dstport, **9 bytes**) ⇄
    snapshot_handler's marker `struct.pack("!BIHH", ...)` (**9 bytes**) ✓
- After handoff, `mesh_proxy.py` got **9 more commits** (Jun 8–9). Three changed the shared
  framing/delivery code and were **never mirrored** into the frozen snapshot_handler:

| commit | change in mesh_proxy.py | snapshot_handler still has | breaks |
|--------|-------------------------|----------------------------|--------|
| **6d07ef9** "more fix" | `recv_buffer` → **4-tuple** (`+exact_local_ip`); data header gained `4s` TargetIP (`!IHH`→`!IHH4s`, parse `data[1:9]`→`data[1:13]`); `process_and_deliver` gained a 6th param; delivery passes `exact_local_ip` | 3-tuple read/write (`:143-145,155`); 5-arg calls | **S2, S3, M1** |
| **9020ba3** "add fix" | the 6th delivery param finalized as **`target_local_ip`** | 5-arg `process_and_deliver(...)` calls (`:137-139,146-152`) | **S1** |
| **2fff8df** "tested" | seq widened **`I`(4B)→`Q`(8B)**: header `!BIHH4s`→**`!BQHH4s`** (17B), ACK `!BI`→`!BQ`, parse `data[1:13]`→`data[1:17]` | marker `struct.pack("!BIHH", ...)` (9B, 4-byte seq, no TargetIP) at `:46` | **S4, S5, M5** |

So the data-packet header grew **9 → 13 → 17 bytes** while snapshot_handler's marker stayed
**9 bytes**, and the delivery contract grew a destination IP that snapshot_handler never
learned about. Every snapshot crash/silent-drop traces to this un-propagated drift, not to
independent logic errors. (At handoff the marker `!BIHH` happened to equal the data header
`!BIHH`, which is *why* it worked then and silently broke later.)

## The port (apply these mesh_proxy changes to snapshot_handler)

1. **Header `!BIHH` → `!BQHH4s` (S4/S5/M5).** `snapshot_handler.py:46`
   `struct.pack("!BIHH", 0, peer_state.send_seq, 0, 0)` must become the current 17-byte data
   framing `struct.pack("!BQHH4s", 0, peer_state.send_seq, src_port, dst_port, target_ip_bytes)`
   so receivers parsing `!QHH4s` over `data[1:17]` can read the marker and ACK the right seq.

2. **`recv_buffer` 4-tuple (S2/S3/M1).** The flush at `:143-145` must unpack 4
   (`payload, src_port, dst_port, exact_local_ip`) and the store at `:155` must write the
   4-tuple — matching `mesh_proxy.py:107,121`.

3. **Pass `target_local_ip` (S1).** The two `process_and_deliver(...)` calls (`:137-139`,
   `:146-152`) must pass the 6th arg. **Prerequisite:** the snapshot cache doesn't even record
   the destination — `process_message` stores only `{seq,payload,src_port,dst_port}`
   (`:79-89`). Porting S1 therefore *also* requires capturing `exact_local_ip` at record time
   (mesh_proxy gained it in 6d07ef9; the snapshot recording path must do the same).

## The real fix is to de-duplicate
`snapshot_handler._finish_global_snapshot` (`:117-156`) is a hand-copied clone of the
in-order delivery + `recv_buffer` flush loop in `mesh_proxy.TunnelProtocol.datagram_received`
(`:93-126`), and the marker framing duplicates the data framing in `_handle_local_intercept`
(`:286-299`). The drift happened **because the logic was copy-pasted**. Extract one shared
helper on `MeshProxy` (e.g. `_deliver_in_order(peer, seq, payload, src_port, dst_port,
local_ip)` and a single `pack_data_header(...)`) and have both call sites use it, so a future
header/tuple/signature change can't desync them again.

## Not caused by the drift (don't expect a mesh_proxy port to fix these)
- **S7** (replay uses already-advanced `recv_seq`) — snapshot-specific logic bug in the same
  loop; needs its own fix (don't advance `recv_seq` for buffered msgs, or replay independently).
- **S6** (`is_snapshotting` never reset on failure) and **S8/M2** (blocking `urllib` on the
  event loop) — snapshot-specific; no mesh_proxy counterpart.
