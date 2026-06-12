import time
import os
import base64
import urllib.request
import json
import socket

from config import SNAPSHOT_TIMEOUT, MESH_MEMBERS, MESH_SELF, SO_MARK, PROXY_MARK


BREAKOUT_URL = os.environ.get("BREAKOUT_URL", "http://10.99.0.1:8989")
# Client-side timeout for the checkpoint POST. Must be >= the receiver's
# COMMAND_TIMEOUT_S (breakout_receiver.py) so we don't give up before it replies.
CHECKPOINT_REQUEST_TIMEOUT_S = 120
# The container to CRIU-checkpoint. Must be set to the *app* container id: the
# sidecar shares the app's network namespace but not its UTS, so gethostname()
# returns the sidecar's own id, which is the wrong target.
CHECKPOINT_TARGET = os.environ.get("CHECKPOINT_TARGET")
# When set, this sidecar is a fresh restore-mode recorder: on startup it loads
# this snapshot's artifact for THIS node (identity = CHECKPOINT_TARGET), seeds
# per-peer send_seq/recv_seq, and replays the recorded channel into the local
# app before serving live traffic. Unset/empty -> normal live sidecar (no-op).
RESTORE_SNAPSHOT_ID = os.environ.get("RESTORE_SNAPSHOT_ID")

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
        # Cached result of _self_mesh_ip() (None = not yet resolved). Static
        # membership minus this IP is the snapshot peer set, so it must be stable.
        self._self_ip_cache = None

    def _self_mesh_ip(self):
        """This node's own mesh IP, used to exclude self from the static cut.

        Returns MESH_SELF if set, else auto-detects by opening a UDP socket and
        connect()-ing to a member (no packet is sent; connect just resolves which
        source IP the kernel would route from). SO_MARK PROXY_MARK keeps the
        socket out of the TPROXY redirect. Result is cached; on any failure
        returns None and logs a warning.
        """
        if MESH_SELF:
            return MESH_SELF
        if self._self_ip_cache is not None:
            return self._self_ip_cache
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.setsockopt(socket.SOL_SOCKET, SO_MARK, PROXY_MARK)
            try:
                sock.connect((MESH_MEMBERS[0], 9))
                ip = sock.getsockname()[0]
            finally:
                sock.close()
            self._self_ip_cache = ip
            return ip
        except Exception as e:
            print(f"[!] Could not auto-detect self mesh IP "
                  f"({type(e).__name__}: {e}); cut may include self")
            return None

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

                self.channel_states.clear()
                self.recorded_send_seq = {}
                self.recorded_recv_seq = {}
                # Derive the cut from STATIC membership, not lazily-discovered
                # self.proxy.peers: every member is marked/recorded even if never
                # warmed, and non-members (e.g. control 10.24.24.200) are excluded.
                self_ip = self._self_mesh_ip()
                members = [ip for ip in MESH_MEMBERS if ip != self_ip]
                self.recording_channels = set(members)
                self.recording_channels.discard(remote_ip)

                # Flush any app-emitted datagrams still pending on the intercept
                # socket so they get PRE-marker seqs (i.e. land on the sending
                # side of this outbound channel cut, not in the recorded state).
                # TODO: maybe consider if we want to change this later
                self.proxy.drain_intercept()

                # Trigger the app's CRIU checkpoint
                self._trigger_app_snapshot_out_of_band(marker_id.decode())

                for peer_ip in members:
                    # Chandy-Lamport: emit the marker on EVERY outgoing channel,
                    # including back toward the origin. Excluding the origin would
                    # leave the initiator waiting on markers that never return.
                    # get_peer() (not .peers[]) so an unwarmed member is created
                    # here and still gets a marker + send-seq capture.
                    peer_state = self.proxy.get_peer(peer_ip)
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
                # cut coordinate = this marker's seq + 1. Gate on static membership
                # so a marker from a non-member origin is not recorded as a channel.
                if remote_ip in members:
                    self.channel_states[remote_ip] = []
                    self.recorded_recv_seq[remote_ip] = seq + 1

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
        container_id = CHECKPOINT_TARGET
        if not container_id:
            # gethostname() is the sidecar's own id (shared netns, separate UTS),
            # not the app container we mean to CRIU-checkpoint, so the export
            # filename would silently target the WRONG container. Make it loud.
            container_id = socket.gethostname()
            print(f"[!] CHECKPOINT_TARGET unset; checkpoint target falls back to "
                  f"sidecar hostname '{container_id}' -- this is almost certainly "
                  f"the WRONG container (set CHECKPOINT_TARGET to the app id)")

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

    def restore_from_artifact(self):
        """
        Restore this node's Chandy-Lamport cut from the durably-stored artifact.

        SELF-GATES on RESTORE_SNAPSHOT_ID: a normal live sidecar leaves it unset,
        so this returns immediately and MeshProxy.start() can call it
        unconditionally. When set, this sidecar is a fresh restore-mode recorder
        whose app was just CRIU-restored; before serving live traffic it:
          - GETs {BREAKOUT_URL}/snapshot/<id> and finds the entry for THIS node
            (node identity = CHECKPOINT_TARGET),
          - seeds each peer's send_seq/recv_seq (skipping nulls), and
          - replays each peer's recorded channel into the local app once, in
            ascending seq order.
        Because every node restores to the SAME cut, sender send_seq and receiver
        recv_seq match by construction, so unacked/recv_buffer are NOT restored.

        Any failure here is logged LOUDLY but swallowed (same discipline as
        _trigger_app_snapshot_out_of_band / _post_artifact): a failed restore must
        not crash the fresh sidecar, which would take down its restored app too.
        """
        if not RESTORE_SNAPSHOT_ID:
            return

        # Catch everything, including ValueError from a malformed BREAKOUT_URL
        # at Request() construction and http.client.HTTPException from urlopen.
        try:
            request = urllib.request.Request(
                f"{BREAKOUT_URL}/snapshot/{RESTORE_SNAPSHOT_ID}"
            )
            with urllib.request.urlopen(
                request, timeout=CHECKPOINT_REQUEST_TIMEOUT_S
            ) as response:
                snapshot = json.loads(response.read().decode("utf-8"))

            node = None
            for entry in snapshot.get("nodes", []):
                if entry.get("node") == CHECKPOINT_TARGET:
                    node = entry
                    break

            if node is None:
                print(f"[!] RESTORE: no artifact for node {CHECKPOINT_TARGET} in "
                      f"snapshot {RESTORE_SNAPSHOT_ID}; nothing to restore")
                return

            peers = node.get("peers", {})
            replayed = 0
            for peer_ip, peer_artifact in peers.items():
                peer_state = self.proxy.get_peer(peer_ip)
                # Skip nulls: the matching cut coordinate on the other side may
                # not have been recorded for this channel direction.
                if peer_artifact.get("send_seq") is not None:
                    peer_state.send_seq = peer_artifact["send_seq"]
                if peer_artifact.get("recv_seq") is not None:
                    peer_state.recv_seq = peer_artifact["recv_seq"]
                    # Pin the restored coordinate so the first live packet does
                    # not overwrite it via the first-contact resync adoption.
                    peer_state.recv_initialized = True

            for peer_ip, peer_artifact in peers.items():
                # These were received+ACKed before the cut; recording only
                # deferred their delivery, so replay = deliver in seq order.
                channel = sorted(
                    peer_artifact.get("channel", []), key=lambda m: m["seq"]
                )
                for msg in channel:
                    payload = base64.b64decode(msg["payload_b64"])
                    self.proxy.process_and_deliver(
                        msg["seq"],
                        payload,
                        peer_ip,
                        msg["src_port"],
                        msg["dst_port"],
                        msg["target_local_ip"],
                    )
                    replayed += 1

            print(f"[*] RESTORE complete for snapshot {RESTORE_SNAPSHOT_ID} "
                  f"(node {CHECKPOINT_TARGET}): {len(peers)} peers restored, "
                  f"{replayed} messages replayed")
        except Exception as e:
            print(f"[!] RESTORE FAILED for snapshot {RESTORE_SNAPSHOT_ID} "
                  f"(node {CHECKPOINT_TARGET}) "
                  f"({type(e).__name__}: {e}); sidecar will serve live traffic "
                  f"WITHOUT restored channel state")

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
        artifact = self._build_artifact("complete")
        # POST the recorded cut to the breakout receiver for durable storage
        # keyed by snapshot_id; build it BEFORE the flush clears the state.
        ok = self._post_artifact(artifact)
        if ok:
            print(f"[*] Global Snapshot Complete! Recorded cut for snapshot "
                  f"{artifact['snapshot_id']} ({len(artifact['peers'])} peers).")
        else:
            # Never claim completion when the POST failed: the cut exists only in
            # this (about-to-be-flushed) process, so the artifact is effectively
            # lost. Make the missing artifact LOUD instead of silent.
            print(f"[!] Snapshot {artifact['snapshot_id']} recorded but PERSIST "
                  f"FAILED; cut NOT stored ({len(artifact['peers'])} peers lost).")
        self._flush_and_reset()

    def _post_artifact(self, artifact):
        """
        POST the recorded Chandy-Lamport cut to the host's breakout receiver
        for durable storage keyed by snapshot_id.

        Any failure here is logged but swallowed (same discipline as
        _trigger_app_snapshot_out_of_band) so a flaky POST cannot wedge the
        controller; a swallowed failure means this node's cut was not persisted.
        Returns True on a successful POST, False on failure, so callers can avoid
        printing a success/Complete message when the cut was not actually stored.
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
            return True
        except Exception as e:
            print(f"[!] PERSIST FAILED for snapshot {artifact['snapshot_id']} "
                  f"({type(e).__name__}: {e}); cut was not stored")
            return False

    def _build_artifact(self, status="complete"):
        """Serialize this node's recorded Chandy-Lamport cut.

        Shape: {snapshot_id, node, status, peers: {peer_ip: {send_seq, recv_seq,
        channel: [{seq, payload_b64, src_port, dst_port, target_local_ip}, ...]}}}.
        status is "complete" (all markers returned) or "aborted" (cut not
        consistent). Payloads are bytes, so they are base64-encoded for JSON. Only
        send_seq, recv_seq, and the recorded channel messages are kept; unacked and
        recv_buffer are deliberately omitted (FIFO RUDP + whole-system restore
        make them recoverable/irrelevant at the cut).
        """
        peers = (
            set(self.recorded_send_seq)
            | set(self.recorded_recv_seq)
            | set(self.channel_states)
        )
        node = CHECKPOINT_TARGET
        if not node:
            # CHECKPOINT_TARGET must be the *app* container id; gethostname()
            # returns the sidecar's own id (shared netns, separate UTS), so the
            # artifact would be filed under the WRONG node and silently look fine.
            node = socket.gethostname()
            print(f"[!] CHECKPOINT_TARGET unset; artifact node id falls back to "
                  f"sidecar hostname '{node}' -- this is almost certainly the "
                  f"WRONG node id (set CHECKPOINT_TARGET to the app container id)")
        return {
            "snapshot_id": (
                self.current_snapshot_id.decode() if self.current_snapshot_id else None
            ),
            "node": node,
            "status": status,
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
        # Emit an "aborted" artifact BEFORE _flush_and_reset clears the state, so
        # a node that received a marker ALWAYS produces a json (complete OR
        # aborted) -- a missing artifact is never silent. Build before the flush.
        artifact = self._build_artifact("aborted")
        if self._post_artifact(artifact):
            print(f"[!] Snapshot {artifact['snapshot_id']} aborted artifact "
                  f"persisted ({reason}); cut is NOT consistent.")
        else:
            print(f"[!] Snapshot {artifact['snapshot_id']} aborted AND aborted "
                  f"artifact PERSIST FAILED ({reason}); nothing stored.")
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
