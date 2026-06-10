#!/usr/bin/env python3
# checkpoint_agent.py -- host-side CRIU checkpoint agent (WORKQUEUE_PLAN.md section 13.1 / 8).
#
# Run as root on each EC2 host:   sudo python3 checkpoint_agent.py
#
# A sidecar entering a snapshot (proxy/snapshot_handler.py:_trigger_app_snapshot_out_of_band)
# POSTs {"container_id": <caller hostname>, "snapshot_id": <uuid>} to
# http://host.containers.internal:9090/checkpoint and BLOCKS until we reply. While it is
# blocked, we checkpoint its app container FIRST, then the sidecar itself -- the caller
# can neither send nor deliver anything in between, so the app+sidecar cut is mutually
# consistent. --leave-running is essential: the live pair must keep recording channel
# state after the cut. --tcp-established is needed because the caller sidecar has this
# very HTTP connection open.
#
# Exports: /tmp/snapshots/<snapshot_id>/<container_name>.tar.zst
# Symlink: /tmp/snapshots/latest -> most recent snapshot dir (concurrent callers share
# one snapshot_id, so racing updates are idempotent; serialized under a lock anyway).

import json
import os
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 9090
SNAP_ROOT = "/tmp/snapshots"

_latest_lock = threading.Lock()


def run(cmd):
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        detail = proc.stderr.strip() or proc.stdout.strip()
        raise RuntimeError(f"`{' '.join(cmd)}` failed (rc={proc.returncode}): {detail}")
    return proc.stdout.strip()


def resolve_pair(container_id):
    """Resolve the caller to its (app, sidecar) container-name pair.

    Names follow the deploy convention <app>-<suffix> / sidecar-<suffix>; the partner
    is the unique other RUNNING container whose name ends in -<suffix>.
    """
    caller = run(["podman", "inspect", "--format", "{{.Name}}", container_id]).lstrip("/")
    if "-" not in caller:
        raise RuntimeError(f"caller {caller!r} does not match the <name>-<suffix> convention")
    suffix = caller.rsplit("-", 1)[1]
    running = run(["podman", "ps", "--format", "{{.Names}}"]).splitlines()
    partners = [n for n in running if n.endswith(f"-{suffix}") and n != caller]
    if len(partners) != 1:
        raise RuntimeError(
            f"expected exactly one running partner for {caller!r} (suffix -{suffix}), "
            f"found {partners or 'none'}"
        )
    partner = partners[0]
    if caller.startswith("sidecar-"):
        return partner, caller
    return caller, partner


def checkpoint(name, snap_dir):
    run([
        "podman", "container", "checkpoint", name,
        "--leave-running", "--tcp-established",
        "--export", os.path.join(snap_dir, f"{name}.tar.zst"),
    ])


def point_latest_at(snap_dir):
    with _latest_lock:
        tmp = os.path.join(SNAP_ROOT, ".latest.tmp")
        if os.path.lexists(tmp):
            os.unlink(tmp)
        os.symlink(snap_dir, tmp)
        os.replace(tmp, os.path.join(SNAP_ROOT, "latest"))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # silence per-request noise; we print our own line
        pass

    def _send(self, code, body, ctype="application/json"):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            self._send(200, "ok", "text/plain")
        else:
            self._send(404, "not found", "text/plain")

    def do_POST(self):
        if self.path != "/checkpoint":
            self._send(404, "not found", "text/plain")
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(length))
            container_id = req["container_id"]
            snapshot_id = req["snapshot_id"]
            if "/" in snapshot_id or ".." in snapshot_id:
                raise RuntimeError(f"bad snapshot_id: {snapshot_id!r}")

            app, sidecar = resolve_pair(container_id)
            snap_dir = os.path.join(SNAP_ROOT, snapshot_id)
            os.makedirs(snap_dir, exist_ok=True)

            t0 = time.time()
            checkpoint(app, snap_dir)      # app first: caller sidecar is blocked right here
            checkpoint(sidecar, snap_dir)  # then the sidecar, mid-blocked-HTTP-call
            dur = time.time() - t0

            point_latest_at(snap_dir)
            print(f"[agent] checkpointed {app} + {sidecar} -> {snap_dir} ({dur:.1f}s)", flush=True)
            self._send(200, json.dumps({
                "status": "ok", "snapshot_dir": snap_dir,
                "containers": [app, sidecar], "duration_s": round(dur, 2),
            }))
        except Exception as e:
            print(f"[agent] checkpoint FAILED: {e}", flush=True)
            self._send(500, json.dumps({"status": "error", "error": str(e)}))


def main():
    os.makedirs(SNAP_ROOT, exist_ok=True)
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"[agent] CRIU checkpoint agent on 0.0.0.0:{PORT}, exporting under {SNAP_ROOT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
