#!/usr/bin/env python3
"""
Verifies the snapshot_handler.py <- mesh_proxy.py port (fixes S1-S5).
Run with proxy/ importable:
    PYTHONPATH=/work/proxy python3 /work/claude_screen/repros/verify_snapshot_fix.py
No root/sockets (spoof socket + HTTP trigger are stubbed). MeshProxy() binds nothing.

This is the FIX counterpart to repro_snapshot_bugs.py (which proved the bugs existed).
After the port, the crashers must NOT fire and the marker must round-trip.
"""
import struct
import sys

sys.path.insert(0, "/work/proxy")
import mesh_proxy  # noqa: E402

results = []
def rec(tag, ok, detail):
    results.append(ok)
    print(f"[{'PASS' if ok else 'FAIL'}] {tag}: {detail}")


class FakeSock:
    def sendto(self, *a):  # swallow spoofed delivery (no IP_TRANSPARENT/root)
        pass


# ---------------------------------------------------------------------------
# S1 + S2 + S3: snapshot replay delivers cached msgs with the correct 6-arg
# process_and_deliver and 4-tuple recv_buffer — no TypeError / ValueError.
# ---------------------------------------------------------------------------
proxy = mesh_proxy.MeshProxy()
proxy.get_spoof_sock = lambda ip, port: FakeSock()  # avoid root sockets
sc = proxy.snapshot_ctrl
ip = "10.24.24.10"
peer = proxy.get_peer(ip)
peer.recv_seq = 0
# Recorded message now carries the destination (post-fix cache shape):
sc.channel_states = {ip: [
    {"seq": 0, "payload": b"m0", "src_port": 1, "dst_port": 2, "target_local_ip": ip},
]}
# A 4-tuple sitting in recv_buffer at the next seq exercises the flush unpack:
peer.recv_buffer[1] = (b"m1", 111, 222, ip)
try:
    sc._finish_global_snapshot()
    rec("S1S2S3_replay_no_crash", peer.recv_seq == 2,
        f"replay delivered seq 0 then flushed buffered seq 1 cleanly; recv_seq={peer.recv_seq}")
except Exception as e:
    rec("S1S2S3_replay_no_crash", False, f"{type(e).__name__}: {e}")


# ---------------------------------------------------------------------------
# S4 + S5: broadcast MARKER is now a well-formed 17-byte data packet; a receiver
# parsing "!QHH4s" recovers the intact "__MARKER__:" payload and the SAME seq the
# sender tracked in unacked (so it will be ACKed, not retransmitted forever).
# ---------------------------------------------------------------------------
proxy2 = mesh_proxy.MeshProxy()
captured = []
class FakeTransport:
    def sendto(self, data, addr):
        captured.append((data, addr))
proxy2.tunnel_transport = FakeTransport()
sc2 = proxy2.snapshot_ctrl
sc2._trigger_app_snapshot_out_of_band = lambda sid: None  # don't block on HTTP
peer2 = proxy2.get_peer("10.24.24.11")  # a peer to broadcast the marker to
send_seq_before = peer2.send_seq
marker_payload = b"__MARKER__:" + b"test-snapshot-id"
# Initiator path: a marker arriving from the local app triggers the broadcast.
sc2.process_message("127.0.0.1", 0, marker_payload, 0, 0, "127.0.0.1")

ok = False
detail = "no marker packet captured"
for data, addr in captured:
    if len(data) >= 17 and data[0] == 0:
        seq, sp, dp, tib = struct.unpack("!QHH4s", data[1:17])
        payload = data[17:]
        if payload.startswith(b"__MARKER__:"):
            seq_match = seq == send_seq_before and send_seq_before in peer2.unacked
            ok = seq_match
            detail = (f"marker parses as 17-byte packet; payload={payload!r}; "
                      f"parsed seq={seq} == sender unacked key={send_seq_before} -> {seq_match}")
            break
rec("S4S5_marker_roundtrips_and_acks", ok, detail)


print("\n==== SUMMARY ====")
passed = sum(results)
print(f"{passed}/{len(results)} checks passed "
      f"({'PORT VERIFIED' if passed == len(results) else 'PORT INCOMPLETE'}).")
print("Note: S6 (is_snapshotting reset), S7 (replay vs advanced recv_seq), and "
      "S8/M2 (blocking urllib) are SEPARATE snapshot-specific bugs, intentionally "
      "out of scope for this port.")
sys.exit(0 if passed == len(results) else 1)
