import asyncio
import ipaddress
import socket
import struct
import time
import uuid
from collections import OrderedDict

from config import *
from snapshot_handler import SnapshotController


class PeerState:
    """Maintain sequence and buffer state per remote node."""

    def __init__(self):
        self.send_seq = 0
        self.unacked = {}  # {seq: (timestamp, packet_bytes)}
        self.recv_seq = 0
        self.recv_buffer = {}  # {seq: (payload_bytes, orig_src_port, orig_dst_port)}


class TunnelProtocol(asyncio.DatagramProtocol):
    """Handles incoming raw UDP packets from the Chandy-Lamport tunnel."""

    def __init__(self, proxy):
        self.proxy = proxy

    def connection_made(self, transport):
        self.proxy.tunnel_transport = transport
        print(
            f"[*] Transparent Mesh Tunnel active on {TUNNEL_PORT} (Mark: {PROXY_MARK})"
        )

    def datagram_received(self, data, addr):
        remote_ip = addr[0]
        peer = self.proxy.get_peer(remote_ip)

        # --- PROBE HANDSHAKE LOGIC ---
        if data == b"__PROBE__":
            self.proxy.tunnel_transport.sendto(b"__PROBE_ACK__", addr)
            return

        if data == b"__PROBE_ACK__":
            if self.proxy.routing_table.get(remote_ip) == "PROBING":
                print(f"[*] Received ACK from {remote_ip}. Upgraded to MESH node.")
                self.proxy.routing_table[remote_ip] = "MESH"
                for payload, src_ip, src_port, dst_port in self.proxy.probe_buffer.pop(
                    remote_ip, []
                ):
                    header = struct.pack("!BIHH", 0, peer.send_seq, src_port, dst_port)
                    packet = header + payload
                    self.proxy.tunnel_transport.sendto(packet, (remote_ip, TUNNEL_PORT))
                    peer.unacked[peer.send_seq] = (time.time(), packet)
                    peer.send_seq += 1
            return

        # --- HEADER PROTECTION ---
        if len(data) < 9:
            return

        msg_type = data[0]

        # Incoming Data Packet (9-byte header)
        if msg_type == 0:
            seq, orig_src_port, orig_dst_port = struct.unpack("!IHH", data[1:9])
            print(
                f"[<-] Received tunnel packet from {remote_ip}. Spoofing delivery to {orig_dst_port}..."
            )

            payload = data[9:]

            ack_packet = struct.pack("!BI", 1, seq)
            self.proxy.tunnel_transport.sendto(ack_packet, (remote_ip, TUNNEL_PORT))

            if seq == peer.recv_seq:
                self.proxy.process_and_deliver(
                    seq, payload, remote_ip, orig_src_port, orig_dst_port
                )
                peer.recv_seq += 1

                while peer.recv_seq in peer.recv_buffer:
                    next_payload, next_src_port, next_dst_port = peer.recv_buffer.pop(
                        peer.recv_seq
                    )
                    self.proxy.process_and_deliver(
                        peer.recv_seq,
                        next_payload,
                        remote_ip,
                        next_src_port,
                        next_dst_port,
                    )
                    peer.recv_seq += 1

            elif seq > peer.recv_seq:
                peer.recv_buffer[seq] = (payload, orig_src_port, orig_dst_port)

        # Incoming ACK Packet
        elif msg_type == 1:
            seq = struct.unpack("!I", data[1:5])[0]
            if seq in peer.unacked:
                del peer.unacked[seq]


class MeshProxy:
    def __init__(self):
        self.peers = {}
        self.spoof_sockets = OrderedDict()  # (src_ip, src_port) -> socket
        self.tunnel_transport = None
        self.local_sock = None
        self.snapshot_ctrl = SnapshotController(self)

        # Async Routing Table & Buffers
        self.routing_table = {}  # IP -> "PROBING", "MESH", or "EXTERNAL"
        self.probe_buffer = {}  # IP -> list of pending packets
        self.mesh_network = ipaddress.ip_network(MESH_SUBNET, strict=False)

    def get_peer(self, ip):
        if ip not in self.peers:
            self.peers[ip] = PeerState()
        return self.peers[ip]

    def get_spoof_sock(self, src_ip, src_port):
        key = (src_ip, src_port)
        if key in self.spoof_sockets:
            self.spoof_sockets.move_to_end(key)
            return self.spoof_sockets[key]

        if len(self.spoof_sockets) >= MAX_SPOOF_SOCKETS:
            _, old_sock = self.spoof_sockets.popitem(last=False)
            old_sock.close()

        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.setsockopt(
            socket.SOL_SOCKET, SO_REUSEPORT, 1
        )  # Note: on older linux headers, you may just need to import SO_REUSEPORT
        sock.setsockopt(socket.SOL_IP, IP_TRANSPARENT, 1)
        sock.setsockopt(socket.SOL_SOCKET, SO_MARK, PROXY_MARK)
        try:
            sock.bind(key)
        except OSError as e:
            print(
                f"[!] TPROXY Bind Fallback for {src_ip}:{src_port}. Using generic outbound socket."
            )
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.setsockopt(socket.SOL_SOCKET, SO_MARK, PROXY_MARK)
        self.spoof_sockets[key] = sock
        return self.spoof_sockets[key]

    def process_and_deliver(self, current_seq, p, ip, src_port, dst_port):
        consumed = self.snapshot_ctrl.process_message(
            ip, current_seq, p, src_port, dst_port
        )

        if not consumed:
            spoof_sock = self.get_spoof_sock(ip, src_port)
            spoof_sock.sendto(p, ("127.0.0.1", dst_port))

    async def _probe_target(self, target_ip):
        """Actively probe an IP to see if it has a proxy sidecar."""
        print(f"[*] Probing {target_ip} for proxy sidecar...")
        if self.tunnel_transport:
            self.tunnel_transport.sendto(b"__PROBE__", (target_ip, TUNNEL_PORT))

        await asyncio.sleep(0.5)

        if self.routing_table.get(target_ip) == "PROBING":
            print(f"[*] Probe to {target_ip} timed out. Marking as EXTERNAL.")
            self.routing_table[target_ip] = "EXTERNAL"
            for data, src_ip, src_port, dst_port in self.probe_buffer.pop(
                target_ip, []
            ):
                spoof_sock = self.get_spoof_sock(src_ip, src_port)
                spoof_sock.sendto(data, (target_ip, dst_port))

    async def start(self):
        loop = asyncio.get_running_loop()

        self.local_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.local_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.local_sock.setsockopt(socket.SOL_IP, IP_RECVORIGDSTADDR, 1)
        self.local_sock.setsockopt(socket.SOL_IP, IP_TRANSPARENT, 1)
        self.local_sock.bind(("0.0.0.0", LOCAL_INTERCEPT_PORT))
        self.local_sock.setblocking(False)
        loop.add_reader(self.local_sock.fileno(), self._handle_local_intercept)

        tunnel_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        tunnel_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        tunnel_sock.setsockopt(socket.SOL_SOCKET, SO_MARK, PROXY_MARK)
        tunnel_sock.bind(("0.0.0.0", TUNNEL_PORT))

        await loop.create_datagram_endpoint(
            lambda: TunnelProtocol(self), sock=tunnel_sock
        )

        asyncio.create_task(self._retransmit_loop())

    def _handle_local_intercept(self):
        """Read intercepted packets, extract original IP:PORT."""
        try:
            while True:
                data, ancdata, flags, addr = self.local_sock.recvmsg(65536, 1024)

                if data.startswith(b"__START_SNAPSHOT__"):
                    snapshot_id = str(uuid.uuid4()).encode()
                    marker_payload = b"__MARKER__:" + snapshot_id
                    self.snapshot_ctrl.process_message(
                        "127.0.0.1", 0, marker_payload, 0, 0
                    )
                    continue

                orig_src_port = addr[1]
                orig_src_ip = addr[0]

                target_ip = None
                target_port = None

                for cmsg_level, cmsg_type, cmsg_data in ancdata:
                    if cmsg_level == socket.SOL_IP and cmsg_type == IP_RECVORIGDSTADDR:
                        target_port = struct.unpack("!H", cmsg_data[2:4])[0]
                        target_ip = socket.inet_ntoa(cmsg_data[4:8])
                        break

                if target_ip and target_port:
                    state = self.routing_table.get(target_ip)

                    if state is None:
                        if ipaddress.ip_address(target_ip) in self.mesh_network:
                            print(
                                f"[*] {target_ip} is in mesh subnet. Initiating probe..."
                            )
                            self.routing_table[target_ip] = "PROBING"
                            self.probe_buffer[target_ip] = [
                                (data, orig_src_ip, orig_src_port, target_port)
                            ]
                            asyncio.create_task(self._probe_target(target_ip))
                        else:
                            self.routing_table[target_ip] = "EXTERNAL"
                            spoof_sock = self.get_spoof_sock(orig_src_ip, orig_src_port)
                            spoof_sock.sendto(data, (target_ip, target_port))

                    elif state == "PROBING":
                        self.probe_buffer[target_ip].append(
                            (data, orig_src_ip, orig_src_port, target_port)
                        )

                    elif state == "MESH":
                        peer = self.get_peer(target_ip)
                        header = struct.pack(
                            "!BIHH", 0, peer.send_seq, orig_src_port, target_port
                        )
                        packet = header + data
                        self.tunnel_transport.sendto(packet, (target_ip, TUNNEL_PORT))
                        peer.unacked[peer.send_seq] = (time.time(), packet)
                        peer.send_seq += 1

                    elif state == "EXTERNAL":
                        spoof_sock = self.get_spoof_sock(orig_src_ip, orig_src_port)
                        spoof_sock.sendto(data, (target_ip, target_port))

        except BlockingIOError:
            pass

    async def _retransmit_loop(self):
        while True:
            now = time.time()
            for ip, peer in self.peers.items():
                for seq, (timestamp, packet) in list(peer.unacked.items()):
                    if now - timestamp > RETRY_TIMEOUT:
                        if self.tunnel_transport:
                            self.tunnel_transport.sendto(packet, (ip, TUNNEL_PORT))
                            peer.unacked[seq] = (now, packet)
            await asyncio.sleep(0.1)


async def main():
    print("[*] Starting Transparent Proxy...")
    proxy = MeshProxy()
    await proxy.start()
    try:
        await asyncio.Event().wait()
    except KeyboardInterrupt:
        print("\n[*] Shutting down...")


if __name__ == "__main__":
    asyncio.run(main())
