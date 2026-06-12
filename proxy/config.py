# config.py

import os

# --- Network Configuration ---
LOCAL_INTERCEPT_PORT = 9000
TUNNEL_PORT = 9001
RETRY_TIMEOUT = 0.5
PROXY_MARK = 99

# --- Application Configuration ---
MESH_SUBNET = "10.24.24.0/24"

# --- Mesh Membership ---
# Static list of mesh node IPs. Snapshot fan-out and the recording set are
# derived from THIS, not from lazily-discovered peers, so an unwarmed node still
# gets a marker and the control container (10.24.24.200) is never recorded.
# Override via env MESH_MEMBERS (comma-separated).
MESH_MEMBERS = [
    ip.strip()
    for ip in os.environ.get(
        "MESH_MEMBERS", "10.24.24.10,10.24.24.11,10.24.24.12"
    ).split(",")
    if ip.strip()
]
# Optional override for this node's own mesh IP; auto-detected if unset.
MESH_SELF = os.environ.get("MESH_SELF")

# --- Snapshot ---
# Seconds to wait for all peer markers before aborting a stuck snapshot.
SNAPSHOT_TIMEOUT = 30.0

# --- Eviction Thresholds ---
MAX_SPOOF_SOCKETS = 512

# --- Linux Kernel Hacks ---
IP_RECVORIGDSTADDR = 20
IP_TRANSPARENT = 19
SO_MARK = 36
SO_REUSEPORT = 15
