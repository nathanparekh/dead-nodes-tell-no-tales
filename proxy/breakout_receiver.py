#!/usr/bin/env python3
"""Host-side breakout receiver: a minimal HTTP API for podman lifecycle ops.

Containers POST JSON here instead of talking to the podman socket. Commands
run synchronously: the HTTP response reports success or failure, and the
single-threaded server serializes concurrent requests.

  POST /checkpoint      {"target_id": ..., "export_path": ...}
  POST /checkpoint-pair {"caller_id": <sidecar hostname>, "snapshot_id": <uuid>}
  POST /restore         {"target_path": ...}
  POST /stop            {"container_id": ...}
  GET  /health

/checkpoint-pair atomically checkpoints the app+sidecar PAIR that the caller
belongs to (work-queue snapshot requirement): the calling sidecar BLOCKS on
this request while we checkpoint its app container FIRST, then the sidecar
itself -- the caller can neither send nor deliver anything in between, so the
app+sidecar cut is mutually consistent. Exports land under
/tmp/snapshots/<snapshot_id>/<name>.tar.zst with a `latest` symlink.

Bind this to an internal interface (the breakout bridge gateway), never
0.0.0.0: anything that can reach it can drive podman as root.
"""

import argparse
import json
import logging
import os
import re
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

COMMAND_TIMEOUT_S = 120
SOCKET_TIMEOUT_S = 30
CONTAINER_ID_RE = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*")

# Where /checkpoint-pair writes its per-snapshot export directories.
SNAP_ROOT = "/tmp/snapshots"
_latest_lock = threading.Lock()


def run(argv: list) -> None:
    subprocess.run(argv, check=True, capture_output=True, text=True,
                   timeout=COMMAND_TIMEOUT_S)


def run_out(argv: list) -> str:
    """Like run(), but return stripped stdout (for podman inspect/ps queries)."""
    proc = subprocess.run(argv, check=True, capture_output=True, text=True,
                          timeout=COMMAND_TIMEOUT_S)
    return proc.stdout.strip()


def checkpoint(target_id: str, export_path: str) -> None:
    run(["sudo", "podman", "container", "checkpoint", target_id,
         "-e", export_path, "--tcp-established", "--leave-running"])


def restore(target_path: str) -> None:
    run(["sudo", "podman", "container", "restore", "-i", target_path,
         "--tcp-established"])


def stop(container_id: str) -> None:
    run(["sudo", "podman", "rm", "-f", container_id])


def resolve_pair(caller_id: str) -> tuple:
    """Resolve the caller to its (app, sidecar) container-name pair.

    Names follow the deploy convention <app>-<suffix> / sidecar-<suffix>; the
    partner is the unique other RUNNING container whose name ends in -<suffix>.
    """
    caller = run_out(["sudo", "podman", "inspect", "--format", "{{.Name}}",
                      caller_id]).lstrip("/")
    if "-" not in caller:
        raise ValueError(f"caller {caller!r} does not match the <name>-<suffix> convention")
    suffix = caller.rsplit("-", 1)[1]
    running = run_out(["sudo", "podman", "ps", "--format", "{{.Names}}"]).splitlines()
    partners = [n for n in running if n.endswith(f"-{suffix}") and n != caller]
    if len(partners) != 1:
        raise ValueError(
            f"expected exactly one running partner for {caller!r} (suffix -{suffix}), "
            f"found {partners or 'none'}"
        )
    partner = partners[0]
    if caller.startswith("sidecar-"):
        return partner, caller
    return caller, partner


def point_latest_at(snap_dir: str) -> None:
    """Atomically repoint /tmp/snapshots/latest at snap_dir (symlink swap)."""
    with _latest_lock:
        tmp = os.path.join(SNAP_ROOT, ".latest.tmp")
        if os.path.lexists(tmp):
            os.unlink(tmp)
        os.symlink(snap_dir, tmp)
        os.replace(tmp, os.path.join(SNAP_ROOT, "latest"))


def checkpoint_pair(caller_id: str, snapshot_id: str) -> dict:
    """App+sidecar atomic checkpoint. Reuses checkpoint() for each container.

    The caller sidecar is blocked on this HTTP request: checkpoint the app
    FIRST (caller can't send/deliver while blocked), then the sidecar itself
    mid-blocked-call. --leave-running --tcp-established (from checkpoint())
    keep the live pair recording channel state and preserve this very HTTP
    connection across the sidecar's own checkpoint.
    """
    app, sidecar = resolve_pair(caller_id)
    snap_dir = os.path.join(SNAP_ROOT, snapshot_id)
    os.makedirs(snap_dir, exist_ok=True)

    t0 = time.time()
    checkpoint(app, os.path.join(snap_dir, f"{app}.tar.zst"))
    checkpoint(sidecar, os.path.join(snap_dir, f"{sidecar}.tar.zst"))
    dur = time.time() - t0

    point_latest_at(snap_dir)
    logging.info("/checkpoint-pair %s + %s -> %s (%.1fs)", app, sidecar, snap_dir, dur)
    return {"ok": True, "snapshot_dir": snap_dir,
            "containers": [app, sidecar], "duration_s": round(dur, 2)}


# Simple routes: handler(*args) returns None; success replies {"ok": True}.
ROUTES = {
    "/checkpoint": (checkpoint, ("target_id", "export_path")),
    "/restore": (restore, ("target_path",)),
    "/stop": (stop, ("container_id",)),
}

# Rich routes: handler(*args) returns the JSON-able body dict to reply with.
RICH_ROUTES = {
    "/checkpoint-pair": (checkpoint_pair, ("caller_id", "snapshot_id")),
}


def field_ok(field: str, value: object) -> bool:
    if not isinstance(value, str):
        return False
    if field.endswith("_path"):
        return value.startswith("/")  # absolute, and can't be read as a flag
    # fullmatch (not match) so a trailing newline can't slip into the argv/logs.
    return CONTAINER_ID_RE.fullmatch(value) is not None


class BreakoutHandler(BaseHTTPRequestHandler):
    timeout = SOCKET_TIMEOUT_S  # drop a client that stalls mid-request

    def log_message(self, format, *args):
        logging.info("%s %s", self.address_string(), format % args)

    def _reply(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._reply(200, {"ok": True})
        else:
            self._reply(404, {"ok": False, "error": "unknown endpoint"})

    def do_POST(self):
        route = ROUTES.get(self.path) or RICH_ROUTES.get(self.path)
        if route is None:
            known = list(ROUTES) + list(RICH_ROUTES)
            self._reply(404, {"ok": False,
                              "error": f"unknown endpoint; expected {'|'.join(known)}"})
            return
        handler, fields = route

        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length))
        except ValueError:
            self._reply(400, {"ok": False, "error": "body must be valid JSON"})
            return
        if not isinstance(body, dict) or set(body) != set(fields):
            self._reply(400, {"ok": False,
                              "error": f"expected exactly fields {sorted(fields)}"})
            return
        bad = [f for f in fields if not field_ok(f, body[f])]
        if bad:
            self._reply(400, {"ok": False,
                              "error": f"invalid value for {bad}: ids must be "
                                       "alphanumeric, paths absolute"})
            return

        args = [body[f] for f in fields]
        try:
            result = handler(*args)
        except ValueError as e:
            # bad pair resolution (no/ambiguous partner, malformed name)
            logging.error("%s %s: %s", self.path, " ".join(args), e)
            self._reply(400, {"ok": False, "error": str(e)})
            return
        except subprocess.CalledProcessError as e:
            stderr = (e.stderr or "").strip()
            logging.error("%s %s: failed (exit %s): %s",
                          self.path, " ".join(args), e.returncode, stderr)
            self._reply(500, {"ok": False, "exit": e.returncode, "stderr": stderr[-2000:]})
            return
        except subprocess.TimeoutExpired:
            logging.error("%s %s: timed out after %ss",
                          self.path, " ".join(args), COMMAND_TIMEOUT_S)
            self._reply(504, {"ok": False,
                              "error": f"command timed out after {COMMAND_TIMEOUT_S}s"})
            return
        logging.info("%s %s: done", self.path, " ".join(args))
        self._reply(200, result if isinstance(result, dict) else {"ok": True})


class InternalHTTPServer(HTTPServer):
    def server_bind(self):
        # IP_FREEBIND (Linux): allow binding the breakout bridge gateway IP
        # even before podman has created the bridge interface.
        try:
            self.socket.setsockopt(socket.IPPROTO_IP,
                                   getattr(socket, "IP_FREEBIND", 15), 1)
        except OSError:
            pass
        super().server_bind()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="10.99.0.1",
                        help="internal interface address to bind (default: breakout bridge gateway)")
    parser.add_argument("--port", type=int, default=8989)
    args = parser.parse_args()
    os.makedirs(SNAP_ROOT, exist_ok=True)  # /checkpoint-pair export root + 'latest' symlink
    server = InternalHTTPServer((args.host, args.port), BreakoutHandler)
    logging.info("breakout receiver listening on %s:%s (pair exports under %s)",
                 args.host, args.port, SNAP_ROOT)
    server.serve_forever()


if __name__ == "__main__":
    main()
