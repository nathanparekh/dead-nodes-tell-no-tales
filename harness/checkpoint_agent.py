#!/usr/bin/env python3
"""Host-side checkpoint agent for the token-ring snapshot demo.

Run as root on EACH of the three EC2 hosts:

    sudo python3 harness/checkpoint_agent.py

Listens on 0.0.0.0:${AGENT_PORT:-9090}.  When a sidecar receives the first
Chandy-Lamport marker, it BLOCKS on POST /checkpoint with
{"container_id": <sidecar short id>, "snapshot_id": <uuid>} and waits for
our reply.  That blocking is the point: the app's memory image is dumped
BEFORE the sidecar broadcasts markers, so a synchronous single-threaded
server is exactly right here.

The sidecar shares the app's network namespace but NOT its UTS namespace,
so gethostname() inside it returns the SIDECAR's own container id.  We map
it to the app container: podman inspect the id, take the "-<suffix>" tail
of its name (sidecar-a -> a), and checkpoint "${APP_PREFIX:-tokenring}-<suffix>".

The checkpoint uses --leave-running, and that flag is load-bearing: a
stop-checkpoint would tear down the app container's network namespace while
the sidecar (which lives inside that netns) is mid-snapshot, killing both
the marker protocol and the sidecar's mesh connectivity.  It also lets the
live ring keep running after the snapshot.

Tarballs land at $SNAP_DIR/<snapshot_id>/<app>.tar.zst
(SNAP_DIR defaults to /var/lib/tokenring-demo).
"""

import json
import os
import re
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer

AGENT_PORT = int(os.environ.get("AGENT_PORT", "9090"))
SNAP_DIR = os.environ.get("SNAP_DIR", "/var/lib/tokenring-demo")
APP_PREFIX = os.environ.get("APP_PREFIX", "tokenring")

SID_RE = re.compile(r"[A-Za-z0-9_-]+\Z")


def log(msg):
    print(msg, flush=True)


def do_checkpoint(container_id, snapshot_id):
    """Map the sidecar's container id to its app container and checkpoint it.

    Returns the tarball path; raises RuntimeError with a readable message
    on any failure.
    """
    if not container_id:
        raise RuntimeError("missing container_id")
    if not snapshot_id or not SID_RE.match(snapshot_id):
        raise RuntimeError("snapshot_id must match [A-Za-z0-9_-]+, got %r" % (snapshot_id,))

    insp = subprocess.run(
        ["podman", "inspect", "--format", "{{.Name}}", container_id],
        capture_output=True, text=True)
    if insp.returncode != 0:
        raise RuntimeError("podman inspect %s failed: %s" % (container_id, insp.stderr.strip()))
    name = insp.stdout.strip().lstrip("/")
    if "-" not in name:
        raise RuntimeError("container name %r has no -<suffix> tail" % name)
    suffix = name.rsplit("-", 1)[1]
    app = "%s-%s" % (APP_PREFIX, suffix)

    outdir = os.path.join(SNAP_DIR, snapshot_id)
    os.makedirs(outdir, exist_ok=True)
    tarball = os.path.join(outdir, app + ".tar.zst")

    cp = subprocess.run(
        ["podman", "container", "checkpoint", "--leave-running",
         "--export", tarball, app],
        capture_output=True, text=True)
    if cp.returncode != 0:
        raise RuntimeError("checkpoint of %s failed: %s" % (app, cp.stderr.strip()))
    return tarball


class Handler(BaseHTTPRequestHandler):
    def _reply(self, code, text):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        code = 200 if self.path == "/health" else 404
        log("GET %s -> %d" % (self.path, code))
        self._reply(code, "ok" if code == 200 else "not found")

    def do_POST(self):
        if self.path != "/checkpoint":
            log("POST %s -> 404" % self.path)
            self._reply(404, "not found")
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            req = json.loads(self.rfile.read(length))
            tarball = do_checkpoint(req.get("container_id"), req.get("snapshot_id"))
        except Exception as e:
            log("POST /checkpoint -> 500: %s" % e)
            self._reply(500, str(e))
            return
        log("POST /checkpoint -> 200: %s" % tarball)
        self._reply(200, "checkpointed: " + tarball)

    def log_message(self, fmt, *args):
        pass  # we emit exactly one line per request ourselves


def main():
    server = HTTPServer(("0.0.0.0", AGENT_PORT), Handler)
    log("checkpoint agent on 0.0.0.0:%d (SNAP_DIR=%s, APP_PREFIX=%s)"
        % (AGENT_PORT, SNAP_DIR, APP_PREFIX))
    server.serve_forever()


if __name__ == "__main__":
    main()
