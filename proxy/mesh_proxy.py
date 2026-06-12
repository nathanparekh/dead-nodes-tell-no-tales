import asyncio
import ipaddress
import random
import socket
import struct
import time
import uuid
from collections import OrderedDict

from config import *
from snapshot_handler import SnapshotController


# Tunnel wire framing — single source of truth for both pack and unpack:
#   data: Type(1) + Seq(8) + SrcPort(2) + DstPort(2) + TargetIP(4) = 17 bytes
#   ack:  Type(1) + Seq(8)                                          = 9 bytes
DATA_HEADER = struct.Struct("!BQHH4s")
ACK_HEADER = struct.Struct("!BQ")
ZERO_IP = b"\x00\x00\x00\x00"


class PeerState:
    """Maintain sequence and buffer state per remote node."""

    def __init__(self):
        self.send_seq = 0
        self.unacked = {}  # {seq: (timestamp, packet_bytes)}
        self.recv_seq = 0
        self.recv_buffer = (
            {}
        )  # {seq: (payload_bytes, orig_src_port, orig_dst_port, exact_local_ip)}


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

        # --- HEADER PROTECTION ---
        if len(data) < 5:
            return

        msg_type = data[0]

        # Incoming Data Packet (17-byte header)
        if msg_type == 0:
            if len(data) < DATA_HEADER.size:
                return

            # Unpack the data header (leading type byte re-read into _)
            _, seq, orig_src_port, orig_dst_port, target_ip_bytes = DATA_HEADER.unpack(
                data[:DATA_HEADER.size]
            )
            exact_local_ip = socket.inet_ntoa(target_ip_bytes)

            payload = data[DATA_HEADER.size:]

            # Send ACK
            ack_packet = ACK_HEADER.pack(1, seq)
            self.proxy.tunnel_transport.sendto(ack_packet, (remote_ip, TUNNEL_PORT))

            # --- STRICT IN-ORDER DELIVERY LOGIC ---
            if seq == peer.recv_seq:
                print(
                    f"[<-] seq {seq} from {remote_ip} (recv_seq {peer.recv_seq}) IN-ORDER. Spoofing delivery to {exact_local_ip}:{orig_dst_port}..."
                )
                self.proxy.process_and_deliver(
                    seq,
                    payload,
                    remote_ip,
                    orig_src_port,
                    orig_dst_port,
                    exact_local_ip,
                )
                peer.recv_seq += 1

                # Flush buffer for any packets that are now in order
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
                print(
                    f"[<-] seq {seq} from {remote_ip} (recv_seq {peer.recv_seq}) FUTURE. Buffering..."
                )
                peer.recv_buffer[seq] = (
                    payload,
                    orig_src_port,
                    orig_dst_port,
                    exact_local_ip,
                )

            else:
                print(
                    f"[<-] seq {seq} from {remote_ip} (recv_seq {peer.recv_seq}) DUPLICATE/STALE. Dropping (ACKed)..."
                )

        # Incoming ACK Packet (9-byte header: Type(1) + Seq(8))
        elif msg_type == 1:
            if len(data) < ACK_HEADER.size:
                return

            seq = ACK_HEADER.unpack(data[:ACK_HEADER.size])[1]
            print(f"[ack] seq {seq} from {remote_ip}")

            if seq in peer.unacked:
                del peer.unacked[seq]


class MeshProxy:
    def __init__(self):
        self.peers = {}
        self.spoof_sockets = OrderedDict()
        self.tunnel_transport = None
        self.local_sock = None
        self.snapshot_ctrl = SnapshotController(self)

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
        sock.setsockopt(socket.SOL_SOCKET, SO_REUSEPORT, 1)
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

    def process_and_deliver(
        self, current_seq, p, ip, src_port, dst_port, target_local_ip
    ):
        consumed = self.snapshot_ctrl.process_message(
            ip, current_seq, p, src_port, dst_port, target_local_ip
        )
        if not consumed:
            spoof_sock = self.get_spoof_sock(ip, src_port)
            spoof_sock.sendto(p, (target_local_ip, dst_port))

    def send_data(self, peer_ip, peer_state, src_port, dst_port, target_ip_bytes, payload):
        """Frame a Type-0 data packet, send it on the tunnel, and track it for retransmit."""
        packet = DATA_HEADER.pack(0, peer_state.send_seq, src_port, dst_port, target_ip_bytes) + payload
        print(f"[->] seq {peer_state.send_seq} to {peer_ip} ({len(payload)}b)")
        self.tunnel_transport.sendto(packet, (peer_ip, TUNNEL_PORT))
        peer_state.unacked[peer_state.send_seq] = (time.time(), packet)
        peer_state.send_seq += 1

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

        # Whole-system restore: replay this node's snapshot artifact into the
        # local app. Self-gates on RESTORE_SNAPSHOT_ID, so this is a no-op when
        # not restoring.
        self.snapshot_ctrl.restore_from_artifact()

    def _forward_intercepted(self, data, ancdata, addr):
        """Route one intercepted app datagram: tunnel if mesh-bound, else direct spoofed send."""
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
            # DIRECT ROUTING LOGIC (No probing)
            if ipaddress.ip_address(target_ip) in self.mesh_network:
                # ASSUME PROXY EXISTS: Wrap and send via tunnel
                peer = self.get_peer(target_ip)
                target_ip_bytes = socket.inet_aton(target_ip)
                self.send_data(
                    target_ip, peer, orig_src_port, target_port, target_ip_bytes, data
                )
            else:
                # OUTSIDE SUBNET: Handle normally (direct spoofed send)
                spoof_sock = self.get_spoof_sock(orig_src_ip, orig_src_port)
                spoof_sock.sendto(data, (target_ip, target_port))

    def _handle_local_intercept(self):
        try:
            while True:
                data, ancdata, flags, addr = self.local_sock.recvmsg(65536, 1024)

                if data.startswith(b"__START_SNAPSHOT__"):
                    prefix = b"__START_SNAPSHOT__:"
                    if data.startswith(prefix):
                        snapshot_id = data[len(prefix):]
                    else:
                        snapshot_id = str(uuid.uuid4()).encode()
                    marker_payload = b"__MARKER__:" + snapshot_id
                    self.snapshot_ctrl.process_message(
                        "127.0.0.1", 0, marker_payload, 0, 0, "127.0.0.1"
                    )
                    continue

                self._forward_intercepted(data, ancdata, addr)

        except BlockingIOError:
            pass

    def drain_intercept(self):
        """Synchronously forward ALL currently-pending app datagrams on the local socket.

        Mirrors the normal (non-__START_SNAPSHOT__) path of _handle_local_intercept,
        assigning sequence numbers / routing each datagram identically. Non-blocking:
        stops on BlockingIOError. Safe to call re-entrantly from within
        _handle_local_intercept's own recv loop.
        """
        try:
            while True:
                data, ancdata, flags, addr = self.local_sock.recvmsg(65536, 1024)
                self._forward_intercepted(data, ancdata, addr)
        except BlockingIOError:
            pass

    async def _retransmit_loop(self):
        while True:
            now = time.time()
            self.snapshot_ctrl.check_timeout()
            for ip, peer in self.peers.items():
                for seq, (timestamp, packet) in list(peer.unacked.items()):
                    if now - timestamp > RETRY_TIMEOUT:
                        if self.tunnel_transport:
                            print(f"[retx] seq {seq} to {ip}")
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
