import socket
import sys
import threading
import time


def receive_messages(sock):
    """Continuously listen for incoming UDP packets."""
    while True:
        try:
            data, addr = sock.recvfrom(1024)
            print(f"[<- RECV] from {addr[0]}:{addr[1]} | {data.decode('utf-8')}")
        except:
            break


def main():
    if len(sys.argv) != 5:
        print(
            "Usage: python auto_test.py <NODE_NAME> <LOCAL_PORT> <PEER_IP> <PEER_PORT>"
        )
        sys.exit(1)

    node_name = sys.argv[1]
    local_port = int(sys.argv[2])
    peer_ip = sys.argv[3]
    peer_port = int(sys.argv[4])

    # Setup Socket
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", local_port))

    print(
        f"[*] {node_name} Active. Listening on {local_port}, blasting {peer_ip}:{peer_port}"
    )

    # Start detached receiver thread
    threading.Thread(target=receive_messages, args=(sock,), daemon=True).start()

    # Main thread blasts messages automatically
    seq = 1
    try:
        while True:
            msg = f"{node_name} Automated Sequence {seq}"
            sock.sendto(msg.encode("utf-8"), (peer_ip, peer_port))
            print(f"[-> SEND] to {peer_ip}:{peer_port} | {msg}")
            seq += 1
            time.sleep(1)  # Change this to 0.1 if you want to stress test it
    except KeyboardInterrupt:
        print(f"\n[*] {node_name} shutting down.")
        sock.close()


if __name__ == "__main__":
    main()
