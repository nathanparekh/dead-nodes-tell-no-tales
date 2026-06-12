import time
import os
import base64
import urllib.request
import json
import socket

from config import SNAPSHOT_TIMEOUT


BREAKOUT_URL = os.environ.get("BREAKOUT_URL", "http://10.99.0.1:8989")
# Client-side timeout for the checkpoint POST. Must be >= the receiver's
# COMMAND_TIMEOUT_S (breakout_receiver.py) so we don't give up before it replies.
CHECKPOINT_REQUEST_TIMEOUT_S = 120
# The container to CRIU-checkpoint. Must be set to the *app* container id: the
# sidecar shares the app's network namespace but not its UTS, so gethostname()
# returns the sidecar's own id, which is the wrong target.
CHECKPOINT_TARGET = os.environ.get("CHECKPOINT_TARGET")

class SnapshotController:
    def __init__(self, proxy_instance):
        self.proxy = proxy_instance

        self.is_snapshotting = False
        self.current_snapshot_id = None
        self.recording_channels = set()
        self.channel_states = {}
        # Per-peer cut coordinates, captured at each channel's marker. Together
        # with channel_states these ARE the Chandy-Lamport channel-state half of
        # the snapshot (the sidecar is the recorder; it is never CRIU-checkpointed).
        self.recorded_send_seq = {}
        self.recorded_recv_seq = {}
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

                # Flush any app-emitted datagrams still pending on the intercept
                # socket so they get PRE-marker seqs (i.e. land on the sending
                # side of this outbound channel cut, not in the recorded state).
                self.proxy.drain_intercept()

                self.channel_states.clear()
                self.recorded_send_seq = {}
                self.recorded_recv_seq = {}
                self.recording_channels = set(self.proxy.peers.keys())
                self.recording_channels.discard(remote_ip)

                for peer_ip, peer_state in self.proxy.peers.items():
                    # Chandy-Lamport: emit the marker on EVERY outgoing channel,
                    # including back toward the origin. Excluding the origin would
                    # leave the initiator waiting on markers that never return.
                    print(f"[*] Broadcasting MARKER to {peer_ip}")
                    # Markers ride the same Type-0 data frame so receivers parse them.
                    self.proxy.send_data(
                        peer_ip, peer_state, 0, 0, b"\x00\x00\x00\x00", payload
                    )
                    # send_data just advanced send_seq to (marker_seq + 1): this
                    # channel's send-side cut coordinate. The restored node resumes
                    # sending from here so the peer's recv_seq lines up exactly.
                    self.recorded_send_seq[peer_ip] = peer_state.send_seq

                for ip in self.recording_channels:
                    self.channel_states[ip] = []

                # The channel the first marker arrived on has empty recorded state
                # (the marker flushed it). Record it explicitly, with its recv-side
                # cut coordinate = this marker's seq + 1.
                if remote_ip in self.proxy.peers:
                    self.channel_states[remote_ip] = []
                    self.recorded_recv_seq[remote_ip] = seq + 1

                # Now waiting for each peer's marker; bound that wait so a peer
                # that dies mid-snapshot can't pin is_snapshotting=True forever.
                self.snapshot_deadline = time.time() + SNAPSHOT_TIMEOUT

                # Trigger the app's CRIU checkpoint AFTER broadcasting markers.
                # Any datagram the app emits between this broadcast and the dump's
                # freeze is a knowingly-accepted microsecond race: this is the
                # pragmatic outbound-boundary ordering, not the airtight
                # freeze-drain-dump version.
                self._trigger_app_snapshot_out_of_band(marker_id.decode())

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
                    # This channel's recv-side cut coordinate: everything up to and
                    # including this marker has been received; resume at seq + 1.
                    self.recorded_recv_seq[remote_ip] = seq + 1
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
        Ask the host's breakout receiver to CRIU-checkpoint this container.

        Any failure here is logged but swallowed so it cannot brick the
        controller (an escape would leave is_snapshotting=True and drop every
        future marker as stale). A swallowed failure means NO app checkpoint
        was taken for this snapshot -- hence the loud marker.
        """
        container_id = CHECKPOINT_TARGET or socket.gethostname()

        # Catch everything, including ValueError from a malformed BREAKOUT_URL
        # at Request() construction and http.client.HTTPException from urlopen.
        try:
            payload = json.dumps({
                "target_id": container_id,
                "export_path": f"/tmp/snapshot-{snapshot_id}-{container_id}.tar.zst",
            }).encode("utf-8")
            request = urllib.request.Request(
                f"{BREAKOUT_URL}/checkpoint",
                data=payload,
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(request, timeout=CHECKPOINT_REQUEST_TIMEOUT_S):
                pass
            print(f"[*] Host checkpointed {container_id} (snapshot {snapshot_id})")
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
        # Assemble the channel-state half of the global snapshot BEFORE the flush
        # clears it. This artifact (per-peer send_seq/recv_seq + recorded in-flight
        # messages) is what a restored sidecar loads instead of being CRIU'd.
        artifact = self._build_artifact()
        # POST the recorded cut to the breakout receiver for durable storage
        # keyed by snapshot_id; build it BEFORE the flush clears the state.
        self._post_artifact(artifact)
        print(f"[*] Global Snapshot Complete! Recorded cut for snapshot "
              f"{artifact['snapshot_id']} ({len(artifact['peers'])} peers).")
        self._flush_and_reset()

    def _post_artifact(self, artifact):
        """
        POST the recorded Chandy-Lamport cut to the host's breakout receiver
        for durable storage keyed by snapshot_id.

        Any failure here is logged but swallowed (same discipline as
        _trigger_app_snapshot_out_of_band) so a flaky POST cannot wedge the
        controller; a swallowed failure means this node's cut was not persisted.
        """
        # Catch everything, including ValueError from a malformed BREAKOUT_URL
        # at Request() construction and http.client.HTTPException from urlopen.
        try:
            payload = json.dumps(artifact).encode("utf-8")
            request = urllib.request.Request(
                f"{BREAKOUT_URL}/snapshot_state",
                data=payload,
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(request, timeout=CHECKPOINT_REQUEST_TIMEOUT_S):
                pass
            print(f"[*] Persisted cut for snapshot {artifact['snapshot_id']}")
        except Exception as e:
            print(f"[!] PERSIST FAILED for snapshot {artifact['snapshot_id']} "
                  f"({type(e).__name__}: {e}); cut was not stored")

    def _build_artifact(self):
        """Serialize this node's recorded Chandy-Lamport cut.

        Shape: {snapshot_id, node, peers: {peer_ip: {send_seq, recv_seq,
        channel: [{seq, payload_b64, src_port, dst_port, target_local_ip}, ...]}}}.
        Payloads are bytes, so they are base64-encoded for JSON. Only send_seq,
        recv_seq, and the recorded channel messages are kept; unacked and
        recv_buffer are deliberately omitted (FIFO RUDP + whole-system restore
        make them recoverable/irrelevant at the cut).
        """
        peers = (
            set(self.recorded_send_seq)
            | set(self.recorded_recv_seq)
            | set(self.channel_states)
        )
        return {
            "snapshot_id": (
                self.current_snapshot_id.decode() if self.current_snapshot_id else None
            ),
            "node": CHECKPOINT_TARGET or socket.gethostname(),
            "peers": {
                peer: {
                    "send_seq": self.recorded_send_seq.get(peer),
                    "recv_seq": self.recorded_recv_seq.get(peer),
                    "channel": [
                        {
                            "seq": m["seq"],
                            "payload_b64": base64.b64encode(m["payload"]).decode("ascii"),
                            "src_port": m["src_port"],
                            "dst_port": m["dst_port"],
                            "target_local_ip": m["target_local_ip"],
                        }
                        for m in self.channel_states.get(peer, [])
                    ],
                }
                for peer in sorted(peers)
            },
        }

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
        self.recorded_send_seq = {}
        self.recorded_recv_seq = {}

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
