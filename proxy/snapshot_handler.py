class SnapshotController:
    def __init__(self, proxy_instance):
        self.proxy = proxy_instance

        self.recording_channels = set()
        self.channel_states = {}

    def process_message(self, remote_ip, seq, payload, src_port, dst_port):
        """
        Process incoming payloads according to snapshot rules.
        Returns:
            True: If the message is a Marker or recorded state (stops main proxy delivery).
            False: If the message should be delivered normally by the main proxy.
        """

        if payload.startswith(b"__MARKER__"):
            print(
                f"[*] Marker received from {remote_ip}. Initiating channel state recording."
            )
            self.recording_channels.add(remote_ip)
            if remote_ip not in self.channel_states:
                self.channel_states[remote_ip] = []

            return True

        if remote_ip in self.recording_channels:
            if payload.startswith(b"__END_SNAPSHOT__"):
                self._finish_snapshot(remote_ip)
                return True
            print(
                f"[*] Recording in-transit message seq {seq} from channel {remote_ip}"
            )
            self.channel_states[remote_ip].append(
                {
                    "seq": seq,
                    "payload": payload,
                    "src_port": src_port,
                    "dst_port": dst_port,
                }
            )

            return True

        return False

    def _finish_snapshot(self, remote_ip):
        print(f"[*] Snapshot complete for {remote_ip}. Resuming normal delivery...")
        self.recording_channels.discard(remote_ip)

        recorded_state = self.channel_states.pop(remote_ip, [])
        peer = self.proxy.get_peer(remote_ip)

        recorded_state.sort(key=lambda x: x["seq"])
        for msg in recorded_state:
            seq = msg["seq"]
            payload = msg["payload"]
            src_port = msg["src_port"]
            dst_port = msg["dst_port"]

            if seq == peer.recv_seq:
                spoof_sock = self.proxy.get_spoof_sock(remote_ip, src_port)
                spoof_sock.sendto(payload, ("127.0.0.1", dst_port))
                peer.recv_seq += 1

                while peer.recv_seq in peer.recv_buffer:
                    next_payload, next_src_port, next_dst_port = peer.recv_buffer.pop(
                        peer.recv_seq
                    )
                    next_sock = self.proxy.get_spoof_sock(remote_ip, next_src_port)
                    next_sock.sendto(next_payload, ("127.0.0.1", next_dst_port))
                    peer.recv_seq += 1

            elif seq > peer.recv_seq:
                peer.recv_buffer[seq] = (payload, src_port, dst_port)
