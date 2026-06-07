import argparse
import socket
import time

parser = argparse.ArgumentParser()
parser.add_argument("--send", action="store_true", help="Send a UDP packets")
parser.add_argument("--recv", action="store_true", help="Receive UDP packets")
parser.add_argument("--ip", type=str, default="127.0.0.1", help="IP address to send to")
parser.add_argument("--port", type=int, default=5005, help="Port to use")
args = parser.parse_args()

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

if args.send:
    counter = 1
    print(f"Sending packets to {args.ip}:{args.port}...")
    try:
        while True:
            message = f"Message sequence number: {counter}"
            sock.sendto(message.encode("utf-8"), (args.ip, args.port))
            print(f"Sent: {message}")
            counter += 1
            time.sleep(0.5)
    except KeyboardInterrupt:
        print("\nStopping...")

elif args.recv:
    sock.bind(("0.0.0.0", args.port))
    print(f"Listening for UDP on port {args.port}...")

    try:
        while True:
            data, addr = sock.recvfrom(1024)
            print(f"Received from {addr[0]}:{addr[1]} -> {data.decode('utf-8')}")
    except KeyboardInterrupt:
        print("\nStopped listening...")
else:
    print("Wrong commands or some shi")
