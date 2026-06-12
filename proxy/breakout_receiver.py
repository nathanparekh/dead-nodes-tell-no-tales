#!/usr/bin/env python3
"""Host-side breakout receiver: a minimal HTTP API for podman lifecycle ops.

Containers POST JSON here instead of talking to the podman socket. Commands
run synchronously: the HTTP response reports success or failure, and the
single-threaded server serializes concurrent requests.

  POST /checkpoint       {"target_id": ..., "export_path": ...}
  POST /checkpoint-pair  {"caller_id": ..., "snapshot_id": ...}
  POST /restore          {"target_path": ...}
  POST /stop             {"container_id": ...}
  POST /snapshot_trigger {"node": ..., "snapshot_id": ...}
  POST /snapshot_state   <artifact dict>
  POST /run_sidecar      {"node": ..., "snapshot_id": ...}
  GET  /snapshot/<snapshot_id>
  GET  /health

Bind this to an internal interface (the breakout bridge gateway), never
0.0.0.0: anything that can reach it can drive podman as root.
"""

import argparse
import glob
import json
import logging
import os
import re
import socket
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

COMMAND_TIMEOUT_S = 120
SOCKET_TIMEOUT_S = 30
CONTAINER_ID_RE = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*")

# Token-ring pair-checkpoint layout: export tarballs under
# $SNAP_DIR/<snapshot_id>/<container>.tar.zst and keep a `latest` symlink.
SNAP_DIR = os.environ.get("SNAP_DIR", "/tmp/snapshots")
# The app container prefix; the sidecar's name tail (e.g. "-a") selects the peer.
APP_PREFIX = os.environ.get("APP_PREFIX", "tokenring")

# Filled in by main() from --mesh-subnet; MESH_BASE is the first three octets.
MESH_SUBNET = "10.24.24.0/24"
MESH_BASE = "10.24.24"

# Filled in by main() from --host/--port; the restore-mode sidecar reads its
# artifact back from this same receiver, so it must be told where we live.
BREAKOUT_URL = "http://10.99.0.1:8989"


def run(argv: list) -> subprocess.CompletedProcess:
    return subprocess.run(argv, check=True, capture_output=True, text=True,
                          timeout=COMMAND_TIMEOUT_S)


def checkpoint(target_id: str, export_path: str) -> None:
    run(["sudo", "podman", "container", "checkpoint", target_id,
         "-e", export_path, "--tcp-established", "--leave-running"])


def restore(target_path: str) -> None:
    run(["sudo", "podman", "container", "restore", "-i", target_path,
         "--tcp-established"])


def stop(container_id: str) -> None:
    run(["sudo", "podman", "rm", "-f", container_id])


def _container_name(container_id: str) -> str:
    """Resolve a container id/name to its canonical podman name (no leading /)."""
    out = run(["sudo", "podman", "inspect", "--format", "{{.Name}}", container_id])
    return out.stdout.strip().lstrip("/")


def checkpoint_pair(caller_id: str, snapshot_id: str) -> None:
    """Atomically checkpoint the app+sidecar PAIR for one token-ring node.

    `caller_id` is the SIDECAR's own container id (it POSTs gethostname(), and
    it shares the app's netns but not its UTS, so that id is the sidecar's).
    We resolve the sidecar's name (e.g. "sidecar-a"), take the "-<suffix>" tail
    to find the app ("<APP_PREFIX>-a"), and checkpoint BOTH with --leave-running
    (load-bearing: a stop-checkpoint would tear down the shared netns mid-marker).

    Tarballs land in $SNAP_DIR/<snapshot_id>/<container>.tar.zst; a `latest`
    symlink is flipped to the new snapshot dir last, so it only ever points at a
    complete checkpoint set.
    """
    sidecar_name = _container_name(caller_id)
    if "-" not in sidecar_name:
        raise ValueError(f"caller name {sidecar_name!r} has no -<suffix> tail")
    suffix = sidecar_name.rsplit("-", 1)[1]
    app_name = f"{APP_PREFIX}-{suffix}"

    outdir = os.path.join(SNAP_DIR, snapshot_id)
    os.makedirs(outdir, exist_ok=True)

    # Checkpoint the app first (it holds the memory image the demo cares about),
    # then the sidecar. Reuse the existing checkpoint() helper for both.
    for name in (app_name, sidecar_name):
        checkpoint(name, os.path.join(outdir, f"{name}.tar.zst"))

    # Flip `latest` atomically: write a new symlink and rename it over the old.
    link = os.path.join(SNAP_DIR, "latest")
    tmp_link = link + ".tmp"
    if os.path.islink(tmp_link) or os.path.exists(tmp_link):
        os.remove(tmp_link)
    os.symlink(snapshot_id, tmp_link)  # relative target: just the snapshot id
    os.replace(tmp_link, link)
    logging.info("checkpoint-pair %s: %s + %s -> %s",
                 snapshot_id, app_name, sidecar_name, outdir)


def snapshot_trigger(node: str, snapshot_id: str) -> None:
    # node/snapshot_id are field_ok-validated (CONTAINER_ID_RE), so no quotes or
    # backslashes can reach the python -c snippet. Any mesh-subnet destination is
    # TPROXY-redirected to the sidecar's intercept port, so the .250 sentinel host
    # need not exist. The app container is APP_PREFIX-<node> (e.g. tokenring-a).
    snippet = (
        "import socket\n"
        "s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)\n"
        f"s.sendto(b'__START_SNAPSHOT__:{snapshot_id}', ('{MESH_BASE}.250', 9999))\n"
        "s.close()\n"
    )
    run(["sudo", "podman", "exec", f"{APP_PREFIX}-{node}", "python3", "-c", snippet])


def run_sidecar(node: str, snapshot_id: str) -> None:
    # node/snapshot_id are field_ok-validated (CONTAINER_ID_RE), so they are safe
    # to interpolate into the container name / env values below. The sidecar joins
    # the already-restored app's netns (APP_PREFIX-<node>, e.g. tokenring-a) and
    # self-gates on RESTORE_SNAPSHOT_ID to replay this node's recorded channel
    # before serving live traffic. Sidecars are never CRIU'd, so --replace just
    # clears any leftover from a prior restore.
    run(["sudo", "podman", "run", "-d", "--replace",
         "--name", f"sidecar-{node}",
         "--network", f"container:{APP_PREFIX}-{node}",
         "--cap-add", "NET_ADMIN",
         "--sysctl", "net.ipv4.ip_nonlocal_bind=1",
         "-e", f"MESH_SUBNET={MESH_SUBNET}",
         "-e", f"BREAKOUT_URL={BREAKOUT_URL}",
         "-e", f"CHECKPOINT_TARGET={APP_PREFIX}-{node}",
         "-e", f"RESTORE_SNAPSHOT_ID={snapshot_id}",
         "sidecar"])


ROUTES = {
    "/checkpoint": (checkpoint, ("target_id", "export_path")),
    "/checkpoint-pair": (checkpoint_pair, ("caller_id", "snapshot_id")),
    "/restore": (restore, ("target_path",)),
    "/stop": (stop, ("container_id",)),
    "/snapshot_trigger": (snapshot_trigger, ("node", "snapshot_id")),
    "/run_sidecar": (run_sidecar, ("node", "snapshot_id")),
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
            return
        if self.path.startswith("/snapshot/"):
            snapshot_id = self.path[len("/snapshot/"):]
            if CONTAINER_ID_RE.fullmatch(snapshot_id) is None:
                self._reply(400, {"ok": False, "error": "invalid snapshot id"})
                return
            nodes = []
            for path in sorted(glob.glob(f"/tmp/snapshot-{snapshot_id}-*.json")):
                with open(path) as f:
                    nodes.append(json.load(f))
            if not nodes:
                self._reply(404, {"ok": False, "error": "unknown snapshot"})
                return
            logging.info("/snapshot/%s: served %d node(s)", snapshot_id, len(nodes))
            self._reply(200, {"snapshot_id": snapshot_id, "nodes": nodes})
            return
        self._reply(404, {"ok": False, "error": "unknown endpoint"})

    def do_POST(self):
        if self.path == "/snapshot_state":
            try:
                length = int(self.headers.get("Content-Length", 0))
                body = json.loads(self.rfile.read(length))
            except ValueError:
                self._reply(400, {"ok": False, "error": "body must be valid JSON"})
                return
            # The nested "peers" is opaque to field_ok; only the two filename-safe
            # identifiers that build the on-disk path are validated here.
            if (not isinstance(body, dict)
                    or not isinstance(body.get("snapshot_id"), str)
                    or not isinstance(body.get("node"), str)
                    or CONTAINER_ID_RE.fullmatch(body["snapshot_id"]) is None
                    or CONTAINER_ID_RE.fullmatch(body["node"]) is None):
                self._reply(400, {"ok": False,
                                  "error": "snapshot_id and node must be "
                                           "filename-safe strings"})
                return
            path = f"/tmp/snapshot-{body['snapshot_id']}-{body['node']}.json"
            with open(path, "w") as f:
                json.dump(body, f)
            logging.info("/snapshot_state %s: wrote %s", body["node"], path)
            self._reply(200, {"ok": True})
            return

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
        except (ValueError, OSError) as e:
            # e.g. checkpoint_pair: unresolvable name tail, or a filesystem error
            # creating the snapshot dir / latest symlink.
            logging.error("%s %s: %s: %s",
                          self.path, " ".join(args), type(e).__name__, e)
            self._reply(500, {"ok": False, "error": f"{type(e).__name__}: {e}"})
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
    global MESH_SUBNET, MESH_BASE, BREAKOUT_URL
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="10.99.0.1",
                        help="internal interface address to bind (default: breakout bridge gateway)")
    parser.add_argument("--port", type=int, default=8989)
    parser.add_argument("--mesh-subnet", default="10.24.24.0/24",
                        help="mesh subnet CIDR; snapshot triggers target <first three octets>.250")
    args = parser.parse_args()
    MESH_SUBNET = args.mesh_subnet
    MESH_BASE = ".".join(MESH_SUBNET.split("/")[0].split(".")[:3])
    BREAKOUT_URL = f"http://{args.host}:{args.port}"
    server = InternalHTTPServer((args.host, args.port), BreakoutHandler)
    logging.info("breakout receiver listening on %s:%s", args.host, args.port)
    server.serve_forever()


if __name__ == "__main__":
    main()
