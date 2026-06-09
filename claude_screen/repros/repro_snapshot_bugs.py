#!/usr/bin/env python3
"""
Runtime proof of the snapshot_handler.py / mesh_proxy.py defects that static
analyzers miss (because SnapshotController.proxy is untyped, pylint/mypy can't
see process_and_deliver's signature).

Run inside a container with the proxy/ dir importable:
    PYTHONPATH=/work/proxy python3 /work/claude_screen/repros/repro_snapshot_bugs.py

Exercises ONLY in-memory logic — no sockets, no root. MeshProxy() binds nothing
in __init__, so this is safe.
"""
import inspect
import struct
import sys

sys.path.insert(0, "/work/proxy")

import mesh_proxy  # noqa: E402
import snapshot_handler  # noqa: E402

PASS, FAIL = "CONFIRMED", "NOT-REPRODUCED"
results = []


def record(tag, ok, detail):
    results.append((tag, ok, detail))
    print(f"[{PASS if ok else FAIL}] {tag}: {detail}")


# ---------------------------------------------------------------------------
# Bug A: snapshot_handler calls proxy.process_and_deliver() with too few args.
# Definition: process_and_deliver(self, current_seq, p, ip, src_port, dst_port,
#                                 target_local_ip)  -> 6 positional (after self)
# snapshot_handler._finish_global_snapshot passes only 5.
# ---------------------------------------------------------------------------
proxy = mesh_proxy.MeshProxy()
sig = inspect.signature(proxy.process_and_deliver)  # bound -> excludes self
required = [p for p in sig.parameters.values()
           if p.default is inspect._empty and p.kind in
           (p.POSITIONAL_ONLY, p.POSITIONAL_OR_KEYWORD)]
print(f"[info] process_and_deliver bound params = {list(sig.parameters)}")
print(f"[info] required positional args = {len(required)}")

sc = proxy.snapshot_ctrl
ip = "10.24.24.10"
proxy.get_peer(ip)  # recv_seq starts at 0
sc.channel_states = {ip: [{"seq": 0, "payload": b"hi", "src_port": 1, "dst_port": 2}]}
try:
    sc._finish_global_snapshot()
    record("BugA_arg_count", False,
           "expected TypeError from 5-arg call to 6-arg process_and_deliver, but none raised")
except TypeError as e:
    record("BugA_arg_count", True,
           f"_finish_global_snapshot -> process_and_deliver raised TypeError: {e}")


# ---------------------------------------------------------------------------
# Bug B: recv_buffer tuple arity mismatch.
# TunnelProtocol stores recv_buffer[seq] as a 4-tuple
# (payload, src_port, dst_port, exact_local_ip).
# snapshot_handler._finish_global_snapshot unpacks it into 3 names.
# Neutralize Bug A first so we reach the recv_buffer flush loop.
# ---------------------------------------------------------------------------
proxy2 = mesh_proxy.MeshProxy()
proxy2.process_and_deliver = lambda *a, **k: None  # isolate Bug B from Bug A
sc2 = proxy2.snapshot_ctrl
ip2 = "10.24.24.11"
peer2 = proxy2.get_peer(ip2)
peer2.recv_seq = 0
# Store a 4-tuple exactly as TunnelProtocol.datagram_received does (mesh_proxy.py ~121):
peer2.recv_buffer[1] = (b"buffered", 111, 222, "10.24.24.11")
sc2.channel_states = {ip2: [{"seq": 0, "payload": b"first", "src_port": 1, "dst_port": 2}]}
try:
    sc2._finish_global_snapshot()
    record("BugB_recv_buffer_arity", False,
           "expected ValueError unpacking 4-tuple into 3 names, but none raised")
except ValueError as e:
    record("BugB_recv_buffer_arity", True,
           f"recv_buffer 4-tuple unpacked into 3 names raised ValueError: {e}")


# ---------------------------------------------------------------------------
# Bug C: broadcast MARKER wire-format is unparseable by the data-packet parser.
# snapshot_handler broadcasts:  struct.pack("!BIHH", 0, seq, 0, 0) + payload  (9-byte header)
# TunnelProtocol sees msg_type==0 and parses a 17-byte header "!QHH4s", then
# payload = data[17:].  The marker prefix is shredded, so startswith fails and
# the receiver never recognizes the marker.
# ---------------------------------------------------------------------------
snap_id = b"123e4567-e89b-12d3-a456-426614174000"
marker_payload = b"__MARKER__:" + snap_id
send_seq = 7
wire = struct.pack("!BIHH", 0, send_seq, 0, 0) + marker_payload  # what snapshot_handler sends
# --- parse exactly as TunnelProtocol.datagram_received (msg_type==0) ---
assert wire[0] == 0, "type byte"
parsed_seq, osp, odp, tib = struct.unpack("!QHH4s", wire[1:17])
recovered_payload = wire[17:]
marker_recognized = recovered_payload.startswith(b"__MARKER__:")
record("BugC_marker_wireformat", not marker_recognized,
       f"sent_seq={send_seq} but parser read seq={parsed_seq}; "
       f"receiver payload={recovered_payload!r}; startswith('__MARKER__:')={marker_recognized} "
       f"(marker silently treated as normal data)")

# Bug C-2: the seq the receiver ACKs (parsed_seq) != the seq the sender tracked
# in unacked (send_seq), so the marker is never ACKed -> retransmitted forever.
record("BugC2_marker_never_acked", parsed_seq != send_seq,
       f"sender unacked key={send_seq}, receiver would ACK seq={parsed_seq} -> "
       f"mismatch means marker is retransmitted indefinitely")


# ---------------------------------------------------------------------------
# Bug D: even if A/B/C were fixed, replay uses peer.recv_seq which
# TunnelProtocol already advanced when it first cached the messages, so the
# replay's `seq == peer.recv_seq` and `seq > peer.recv_seq` are both false and
# the buffered messages are silently dropped. Demonstrate the comparison.
# ---------------------------------------------------------------------------
proxy3 = mesh_proxy.MeshProxy()
delivered = []
proxy3.process_and_deliver = lambda *a, **k: delivered.append(a)
sc3 = proxy3.snapshot_ctrl
ip3 = "10.24.24.12"
peer3 = proxy3.get_peer(ip3)
# Simulate that seqs 0 and 1 were received & cached during recording, so recv_seq
# has already advanced to 2 (TunnelProtocol increments it regardless of caching).
peer3.recv_seq = 2
sc3.channel_states = {ip3: [
    {"seq": 0, "payload": b"m0", "src_port": 1, "dst_port": 2},
    {"seq": 1, "payload": b"m1", "src_port": 1, "dst_port": 2},
]}
sc3._finish_global_snapshot()
record("BugD_replay_dropped", len(delivered) == 0,
       f"recv_seq already advanced to 2; replay of seqs [0,1] delivered "
       f"{len(delivered)} messages (expected 0 -> buffered traffic lost on replay)")


print("\n==== SUMMARY ====")
confirmed = sum(1 for _, ok, _ in results if ok)
for tag, ok, _ in results:
    print(f"  {tag}: {'CONFIRMED' if ok else 'not reproduced'}")
print(f"{confirmed}/{len(results)} defects reproduced.")
# Exit 0 always: this script is evidence, not a pass/fail gate.
sys.exit(0)
