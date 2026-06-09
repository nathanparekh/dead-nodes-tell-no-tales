import struct
import time
import os
import urllib.request
import json
import socket

from config import TUNNEL_PORT


class SnapshotController:
    def __init__(self, proxy_instance):
        self.proxy = proxy_instance

        self.is_snapshotting = False
        self.current_snapshot_id = None
        self.recording_channels = set()
        self.channel_states = {}

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
        Use CRIU to snapshot the application.
        """
        container_id = socket.gethostname()

        print("[!] Out-of-Band Signal: Telling local app to snapshot memory NOW!")
        agent_url = "http://host.containers.internal:9090/checkpoint"
        payload = json.dumps(
            {"container_id": container_id, "snapshot_id": snapshot_id}
        ).encode("utf-8")

        try:
            req = urllib.request.Request(
                agent_url, data=payload, headers={"Content-Type": "application/json"}
            )
            with urllib.request.urlopen(req, timeout=30) as response:
                if response.status == 200:
                    print("[*] Host Agent confirmed checkpoint completion.")
        except Exception as e:
            print(
                f"[!] FATAL: Failed to reac Checkpoint Interface or checkpoint failed! {e}"
            )

    def _finish_global_snapshot(self):
        print("[*] Global Snapshot Complete! Flushing all cached channels...")
        self.is_snapshotting = False
        self.current_snapshot_id = None

        for remote_ip, recorded_state in self.channel_states.items():
            if not recorded_state:
                continue

            peer = self.proxy.get_peer(remote_ip)

            recorded_state.sort(key=lambda x: x["seq"])

            for msg in recorded_state:
                seq = msg["seq"]
                payload = msg["payload"]
                src_port = msg["src_port"]
                dst_port = msg["dst_port"]
                target_local_ip = msg["target_local_ip"]

                if seq == peer.recv_seq:
                    self.proxy.process_and_deliver(
                        seq, payload, remote_ip, src_port, dst_port, target_local_ip
                    )
                    peer.recv_seq += 1

                    while peer.recv_seq in peer.recv_buffer:
                        next_payload, next_src_port, next_dst_port, next_local_ip = (
                            peer.recv_buffer.pop(peer.recv_seq)
                        )
                        self.proxy.process_and_deliver(
                            peer.recv_seq,
                            next_payload,
                            remote_ip,
                            next_src_port,
                            next_dst_port,
                            next_local_ip,
                        )
                        peer.recv_seq += 1
                elif seq > peer.recv_seq:
                    peer.recv_buffer[seq] = (
                        payload,
                        src_port,
                        dst_port,
                        target_local_ip,
                    )
        self.channel_states.clear()
