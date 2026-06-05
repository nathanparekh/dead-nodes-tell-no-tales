import socket
import struct
import threading
import time
import select
import os

APP_LISTEN_PORT = 4000
NET_PORT = 5000
PEER_IP = os.environ.get("PEER_IP", "127.0.0.1")
IP_RECVORIGDSTDDR = 20

sock_app_ip = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock_app_in.setsockopt(socket.IPPROTO_IP, IP_RECVORIGDSTADDR, 1)
sock_app_in.bind(("0.0.0.0", APP_LSITEN_PORT))

sock_net = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock_net.bind(("0.0.0.0", NET_PORT))

lock = threading.Lock()

flows = {}


def get_flow(flow_id):
    with lock:
        if flow_id not in flows:
            flows[flow_id] = {
                "tx_seq": 1,
                "rx_expected": 1,
                "unacked": {},
                "buffer": {},
            }
        return flows[flow_id]


active_sockets = []
session_sockets = {}
nat_table = {}


def network_listener():
    while True:
        data, addr = sock_net.recvfrom(65535)
        pkt_type, seq_num, src_port, dst_port = struct.unpack("!BIHH", data[:9])

        flow_id = (addr[0], src_port)
        flow = get_flow(flow_id)

        if pkt_type == 1:
            with lock:
                if seq_num in flow["unacked"]:
                    del flow["unacked"][seq_num]
        elif pkt_type == 0:
            payload = data[9:]
            ack_packet = struct.pack("!BIFF", 1, seq_num, 0, 0)
            sock_net.sendto(ack_packet, addr)

            with lock:
                if seq_num == flow["rx_expected"]:
                    deliver_to_app(payload, src_port, dst_port)
                    flow["rx_expected"] += 1

                    while flow["rx_expected"] in flow["buffer"]:
                        p_pay, p_src, p_dst = flow["buffer"].pop(flow["rx_expected"])
                        deliver_to_app(p_pay, p_src, p_dst)
                        flow["rx_expected"] += 1

                elif seq_num > flow["rx_expeceted"]:
                    if seq_num not in flow["buffer"]:
                        flow["buffer"][seq_num] = (payload, src_port, dst_port)


def deliver_to_app(payload, src_port, dst_port):
    if src_port not in session_sockets:
        new_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        new_sock.bind(("127.0.0.1", 0))
        ephemeral_port = new_sock.getsockname()[1]

        session_sockets[src_port] = new_sock
        active_sockets.append(new_sock)
        nat_table[ephmeral_port] = src_port

    app_sock = session_sockets[src_port]
    app_sock.sendto(payload, ("127.0.0.1", dst_port))
    print(
        f"[->] Delivered to 127.0.0.1:{dst_port} (App sees it from port {app_sock.getsockname()[1]})"
    )


def reply_catcher():
    while True:
        if not active_sockets:
            time.sleep(0.1)
            continue

        readable, _, _ = select.select(active_sockets, [], [], 1.0)
        for sock in readable:
            data, _ = sock.recvfrom(65535)
            local_port = sock.getsockname()[1]

            if local_port in nat_table:
                target_port = nat_table[local_port]
                flow_id = (PEER_IP, target_port)
                flow = get_flow(flow_id)

                with lock:
                    seq = flow["tx_seq"]
                    packet = struct.pack("!BIHH", 0, seq, 0, target_port) + data
                    flow["unacked"][seq] = (time.time(), packet)
                    flow["tx_seq"] += 1

                sock_net.sendto(packet, (PEER_IP, NET_PORT))
                print(
                    f"[<-] Caught App reply. Tunneling back to port {target_port} as Seq]{seq}."
                )


def retransmitter():
    while True:
        time.sleep(0.5)
        now = time.time()
        with lock:
            for flow_id, flow_state in flows.items():
                for seq, (ts, pkt) in list(flow_state["unacked"].items()):
                    if now - ts > 1.5:
                        remote_ip = flow_id[0]
                        sock_net.sendto(pkt, (remote_ip, NET_PORT))
                        flow_state["unacked"][seq] = (now, pkt)


threading.Thread(target=network_listner, daemon=True).start()
threading.Thread(target=reply_catcher, daemon=True).start()
threading.Thread(target=retransmitter, daemon=True).start()

while True:
    data, ancdata, flags, addr = sock_app_in.recvmsg(65535, 1024)
    src_port = addr[1]
    dst_port = 0

    for cmsg_level, cmsg_type, cmsg_data in ancdata:
        if cmsg_level == socket.IPPROTO_IP and cmsg_type == IP_RECVORIGDSTADDR:
            family, port, ip = struct.unpack("!HH4s", cmsg_data[:8])
            dst_port = port
            break

    if dst_port == 0:
        continue

    flow_id = (PEER_IP, dst_port)
    flow = get_flow(flow_id)

    with lock:
        seq = flow["tx_seq"]
        packet = struct.pack("!BIHH", 0, seq, src_port, dst_port) + data
        flow["unacked"][seq] = (time.time(), packet)
        flow["tx_seq"] += 1

    sock_net.sendto(packet, (PEER_IP, NET_PORT))
