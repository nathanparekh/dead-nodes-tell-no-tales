import socket
import time

UDP_IP = "receiver"  # Resolves via the Podman network
UDP_PORT = 5005

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
counter = 0

print(f"Starting to send UDP packets to {UDP_IP}:{UDP_PORT}...", flush=True)

while True:
    message = str(counter).encode("utf-8")
    sock.sendto(message, (UDP_IP, UDP_PORT))
    print(f"Sent: {counter}", flush=True)
    counter += 1
    time.sleep(1)
