import struct
import time
import os
import urllib.request
import json
import socket

from config import TUNNEL_PORT, SNAPSHOT_TIMEOUT


BREAKOUT_URL = os.environ.get("BREAKOUT_URL", "http://10.99.0.1:8989")
# The pair checkpoint resolves the (app, sidecar) pair from the caller's own
# container name on the host, so the sidecar only needs to POST its own
# hostname -- no CHECKPOINT_TARGET env is required anymore.

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

                for peer_ip, peer_state in self.proxy.peers.items():
                    if peer_ip != remote_ip:
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
        Ask the host's breakout receiver to CRIU-checkpoint the app+sidecar PAIR.

        We POST our own sidecar hostname as caller_id; the receiver's
        /checkpoint-pair resolves the (app, sidecar) pair from it and
        checkpoints the app FIRST, then this sidecar -- while this very HTTP
        request blocks, so the pair cut is mutually consistent (the work-queue
        snapshot correctness requirement). Exports land under
        /tmp/snapshots/<snapshot_id>/.

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
        self.is_snapshotting = False
        self.current_snapshot_id = None
        self.snapshot_deadline = None
        self.recording_channels = set()

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
