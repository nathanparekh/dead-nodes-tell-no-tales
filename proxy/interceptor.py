import socket
import queue
import threading
import sys

LISTEN_IP = "0.0.0.0"
LISTEN_PORT = 5005

DEST_IP = "real-receiver"
DEST_PORT = 5005

sock_in = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock_in.bind((LISTEN_IP, LISTEN_PORT))
sock_out = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

packet_queue = queue.Queue()


def capture():
    while True:
        data, addr = sock_in.recvfrom(1024)
        packet_queue.put(data)
        sys.stdout.write(
            f"\r[+] Caught packet: '{data.decode('utf-8')}'. (Queued: {packet_queue.qsize()})\n> "
        )
        sys.stdout.flush()


threading.Thread(target=capture, daemon=True).start()

print("Type 'all' to empty the queue.")

while True:
    try:
        sys.stdout.write("> ")
        sys.stdout.flush()
        cmd = sys.stdin.readline().strip().lower()

        if cmd == "all":
            count = 0
            while not packet_queue.empty():
                data = packet_queue.get()
                sock_out.sendto(data, (DEST_IP, DEST_PORT))
                count += 1
            print(f"[-] Forwareded {count} packets.", flush=True)
        else:
            if not packet_queue.empty():
                data = packet_queue.get()
                sock_out.sendto(data, (DEST_IP, DEST_PORT))
                print(f"[-] Forwarded: '{data.decode('utf-8')}'.", flush=True)
            else:
                print(f"[!] Queue is empty.", flush=True)
    except KeyboardInterrupt:
        print("\nExiting...")
        sys.exit(0)
