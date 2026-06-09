# config.py

# --- Network Configuration ---
LOCAL_INTERCEPT_PORT = 9000
TUNNEL_PORT = 9001
RETRY_TIMEOUT = 0.5
PROXY_MARK = 99
PROBE_COOLDOWN = 5.0 

# --- Application Configuration ---
MESH_SUBNET = "10.24.24.0/24"

# --- Eviction Thresholds ---
MAX_SPOOF_SOCKETS = 512

# --- Linux Kernel Hacks ---
IP_RECVORIGDSTADDR = 20
IP_TRANSPARENT = 19
SO_MARK = 36
SO_REUSEPORT = 15
