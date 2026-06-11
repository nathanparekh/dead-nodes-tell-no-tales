import struct
import time
import os
import urllib.request
import json
import socket
import base64

from config import TUNNEL_PORT, SNAPSHOT_TIMEOUT


BREAKOUT_URL = os.environ.get("BREAKOUT_URL", "http://10.99.0.1:8989")


class SnapshotController:
    def __init__(self, proxy_instance):
        self.proxy = proxy_instance

        self.is_snapshotting = False
        self.current_snapshot_id = None
        self.recording_channels = set()
        self.channel_states = {}
        self.snapshot_deadline = None

    def process_message(self, remote_ip, seq, payload, src_port, dst_port, target_local_ip):
        """
        Process incoming payloads according to snapshot rules.
        Returns:
            True: If the message is a Marker or recorded state (stops main proxy delivery).
            False: If the message should be delivered normally by the main proxy.
        """

        if payload.startswith(b"__MARKER__:"):
            marker_id = payload.split(b":", 1)[1]

            if not self.is_snapshotting:
                print(
                    f"[*] Marker received from {remote_ip}. Initiating channel state recording."
                )
                self.is_snapshotting = True
                self.current_snapshot_id = marker_id
                self._trigger_app_snapshot_out_of_band(marker_id.decode())

                self.channel_states.clear()
                self.recording_channels = set(self.proxy.peers.keys())
                self.recording_channels.discard(remote_ip)

                # Chandy-Lamport: send the marker on ALL outgoing channels,
                # including back to the peer it came from. Otherwise the
                # initiator (whose marker reaches everyone first) never gets
                # markers back, never terminates, and swallows every later
                # message on its recorded channels.
                for peer_ip, peer_state in self.proxy.peers.items():
                    print(f"[*] Broadcasting MARKER to {peer_ip}")
                    # Must match mesh_proxy's data framing so receivers can parse it:
                    # Type(1) + Seq(8) + SrcPort(2) + DstPort(2) + TargetIP(4) = 17 bytes
                    header = struct.pack(
                        "!BQHH4s", 0, peer_state.send_seq, 0, 0, b"\x00\x00\x00\x00"
                    )
                    packet = header + payload
                    self.proxy.tunnel_transport.sendto(
                        packet, (peer_ip, TUNNEL_PORT)
                    )
                    peer_state.unacked[peer_state.send_seq] = (time.time(), packet)
                    peer_state.send_seq += 1

                for ip in self.recording_channels:
                    self.channel_states[ip] = []

                # Now waiting for each peer's marker; bound that wait so a peer
                # that dies mid-snapshot can't pin is_snapshotting=True forever.
                self.snapshot_deadline = time.time() + SNAPSHOT_TIMEOUT

                if not self.recording_channels:
                    self._finish_global_snapshot()

            else:

                if marker_id != self.current_snapshot_id:
                    print(
                        f"[!] Ghost/Stale marker received (ID: {marker_id.decode()}). Ignored."
                    )
                    return True

                if remote_ip in self.recording_channels:
                    print(
                        f"[*] Marker received from {remote_ip}. Finalizing this channel's state."
                    )
                    self.recording_channels.discard(remote_ip)

                    if not self.recording_channels:
                        self._finish_global_snapshot()

            return True

        if self.is_snapshotting and remote_ip in self.recording_channels:
            print(f"[*] Caching in-flight message seq {seq} from {remote_ip}")
            self.channel_states[remote_ip].append(
                {
                    "seq": seq,
                    "payload": payload,
                    "src_port": src_port,
                    "dst_port": dst_port,
                    "target_local_ip": target_local_ip,
                }
            )
            return True

        return False

    def _trigger_app_snapshot_out_of_band(self, snapshot_id):
        """
        Ask the host's breakout receiver to atomically CRIU-checkpoint the
        app+sidecar PAIR for this node (the token-ring correctness requirement).

        We POST our OWN container name as caller_id: this code runs inside the
        sidecar, which shares the app's network namespace but not its UTS, so
        gethostname() returns the sidecar's id. The receiver resolves that to
        the app/sidecar pair and checkpoints both with --leave-running.

        Any failure here is logged but swallowed so it cannot brick the
        controller (an escape would leave is_snapshotting=True and drop every
        future marker as stale). A swallowed failure means NO app checkpoint
        was taken for this snapshot -- hence the loud marker.
        """
        caller_id = socket.gethostname()

        # Catch everything, including ValueError from a malformed BREAKOUT_URL
        # at Request() construction and http.client.HTTPException from urlopen.
        try:
            payload = json.dumps({
                "caller_id": caller_id,
                "snapshot_id": snapshot_id,
            }).encode("utf-8")
            request = urllib.request.Request(
                f"{BREAKOUT_URL}/checkpoint-pair",
                data=payload,
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(request, timeout=120):
                pass
            print(f"[*] Host checkpointed pair for {caller_id} (snapshot {snapshot_id})")
        except Exception as e:
            print(f"[!] CHECKPOINT FAILED for snapshot {snapshot_id} "
                  f"({type(e).__name__}: {e}); no app state was saved")

    def check_timeout(self):
        """Abort a snapshot whose markers never all came back. Called periodically."""
        if (
            self.is_snapshotting
            and self.snapshot_deadline is not None
            and time.time() > self.snapshot_deadline
        ):
            self._abort_snapshot("timed out waiting for markers")

    def _finish_global_snapshot(self):
        print("[*] Global Snapshot Complete! Flushing all cached channels...")
        self._flush_and_reset()

    def _abort_snapshot(self, reason):
        # Deliver the buffered traffic anyway so an incomplete snapshot doesn't
        # black-hole the mesh; just don't claim a consistent cut was taken.
        print(f"[!] Snapshot {self.current_snapshot_id} aborted ({reason}); "
              f"delivering buffered traffic and resetting.")
        self._flush_and_reset()

    def _flush_and_reset(self):
        # Token-ring addition: persist the recorded channel state to a JSON file
        # BEFORE replaying (which clears channel_states). The demo kills the
        # containers after the snapshot, so this on-disk dump is the only durable
        # copy harness/replay_channels.py can replay into the restored nodes.
        # Written on every reset (finish AND abort) so the harness always finds
        # a file. sid is read here, before current_snapshot_id is cleared.
        sid = self.current_snapshot_id.decode() if self.current_snapshot_id else "unknown"

        self.is_snapshotting = False
        self.current_snapshot_id = None
        self.snapshot_deadline = None
        self.recording_channels = set()

        try:
            channels = {
                ip: [
                    {
                        "seq": m["seq"],
                        "payload_b64": base64.b64encode(m["payload"]).decode(),
                        "src_port": m["src_port"],
                        "dst_port": m["dst_port"],
                    }
                    for m in sorted(msgs, key=lambda x: x["seq"])
                ]
                for ip, msgs in self.channel_states.items()
            }
            with open(f"/tmp/channel_states_{sid}.json", "w") as f:
                json.dump({"snapshot_id": sid, "channels": channels}, f)
        except Exception as e:
            print(f"[!] WARNING: failed to write channel state dump: {e}")

        # Recorded messages were already received and ACKed by the RUDP layer
        # (recv_seq advanced at receipt); recording only deferred their delivery
        # to the app. So replay = deliver in recorded order. Do NOT re-gate on
        # peer.recv_seq (it has moved past these seqs) and do NOT touch
        # recv_buffer (it holds future out-of-order packets, not part of this cut).
        for remote_ip, recorded_state in self.channel_states.items():
            recorded_state.sort(key=lambda x: x["seq"])
            for msg in recorded_state:
                self.proxy.process_and_deliver(
                    msg["seq"],
                    msg["payload"],
                    remote_ip,
                    msg["src_port"],
                    msg["dst_port"],
                    msg["target_local_ip"],
                )
        self.channel_states.clear()
