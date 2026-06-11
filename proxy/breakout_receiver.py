#!/usr/bin/env python3
"""Host-side breakout receiver: a minimal HTTP API for podman lifecycle ops.

Containers POST JSON here instead of talking to the podman socket. Commands
run synchronously: the HTTP response reports success or failure, and the
single-threaded server serializes concurrent requests.

  POST /checkpoint {"target_id": ..., "export_path": ...}
  POST /restore    {"target_path": ...}
  POST /stop       {"container_id": ...}
  GET  /health

Bind this to an internal interface (the breakout bridge gateway), never
0.0.0.0: anything that can reach it can drive podman as root.
"""

import argparse
import json
import logging
import re
import socket
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

COMMAND_TIMEOUT_S = 120
SOCKET_TIMEOUT_S = 30
CONTAINER_ID_RE = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*")


def run(argv: list) -> None:
    subprocess.run(argv, check=True, capture_output=True, text=True,
                   timeout=COMMAND_TIMEOUT_S)


def checkpoint(target_id: str, export_path: str) -> None:
    run(["sudo", "podman", "container", "checkpoint", target_id,
         "-e", export_path, "--tcp-established", "--leave-running"])


def restore(target_path: str) -> None:
    run(["sudo", "podman", "container", "restore", "-i", target_path,
         "--tcp-established"])


def stop(container_id: str) -> None:
    run(["sudo", "podman", "rm", "-f", container_id])


ROUTES = {
    "/checkpoint": (checkpoint, ("target_id", "export_path")),
    "/restore": (restore, ("target_path",)),
    "/stop": (stop, ("container_id",)),
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
        route = ROUTES.get(self.path)
        if route is None:
            self._reply(404, {"ok": False,
                              "error": f"unknown endpoint; expected {'|'.join(ROUTES)}"})
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
            handler(*args)
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
        self._reply(200, {"ok": True})


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
    server = InternalHTTPServer((args.host, args.port), BreakoutHandler)
    logging.info("breakout receiver listening on %s:%s", args.host, args.port)
    server.serve_forever()


if __name__ == "__main__":
    main()
