#!/usr/bin/env python3
"""Offline logic test for proxy/breakout_receiver.py's artifact snapshot/restore API.

No podman, no CRIU, no containers: we put a fake `sudo`/`podman` on PATH that
simulates `podman container checkpoint` (touches the export tar), then drive the
REAL HTTP server. This exercises main's artifact model end-to-end at the
receiver boundary:

  POST /checkpoint       -> the sidecar-driven CRIU export of THIS node's app
  POST /snapshot_state   -> persists this node's recorded Chandy-Lamport cut as
                            /tmp/snapshot-<id>-<node>.json
  GET  /snapshot/<id>    -> the restore-mode sidecar reads back every node's cut

It also asserts the pre-existing /health and field validation behaviour, and
that the removed branch (app+sidecar) model is gone: its trigger endpoint and
its module-level export-root/helper symbols no longer exist. The app container
here is `workqueue-a` (the workqueue app's container name), matching
build_workqueue.sh.

Run: python3 test/test_breakout_pair.py   -> prints "BREAKOUT-ARTIFACT PASS" / exit 0
"""

import glob
import importlib.util
import json
import os
import shutil
import stat
import sys
import tempfile
import threading
import urllib.request
from http.server import HTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD_PATH = os.path.join(ROOT, "proxy", "breakout_receiver.py")

FAILURES = []


def check(cond, msg):
    if cond:
        print(f"  ok: {msg}")
    else:
        print(f"  FAIL: {msg}")
        FAILURES.append(msg)


def load_module():
    spec = importlib.util.spec_from_file_location("breakout_receiver", MOD_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def install_fake_podman(bindir):
    """Write fake `sudo` and `podman` shims.

    podman container checkpoint <name> -e <path> ...  -> touch <path>, rc 0
    sudo <argv...>                                     -> exec argv (transparent)

    Only /checkpoint reaches podman in this test; /snapshot_state and
    /snapshot/<id> are pure host-FS operations.
    """
    podman = os.path.join(bindir, "podman")
    with open(podman, "w") as f:
        f.write(
            "#!/usr/bin/env python3\n"
            "import sys\n"
            "a = sys.argv[1:]\n"
            "if a[:2] == ['container', 'checkpoint']:\n"
            "    # find the -e <export_path> arg and touch it\n"
            "    path = a[a.index('-e') + 1]\n"
            "    open(path, 'wb').close()\n"
            "    sys.exit(0)\n"
            "else:\n"
            "    sys.stderr.write('fake-podman: unhandled ' + ' '.join(a))\n"
            "    sys.exit(7)\n"
        )
    sudo = os.path.join(bindir, "sudo")
    with open(sudo, "w") as f:
        f.write('#!/bin/sh\nexec "$@"\n')
    for p in (podman, sudo):
        os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


def post(url, obj):
    data = json.dumps(obj).encode("utf-8")
    req = urllib.request.Request(url, data=data,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def get(url):
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def main():
    mod = load_module()

    tmpdir = tempfile.mkdtemp(prefix="breakout_test_")
    bindir = os.path.join(tmpdir, "bin")
    os.makedirs(bindir)
    install_fake_podman(bindir)
    os.environ["PATH"] = bindir + os.pathsep + os.environ["PATH"]

    # /snapshot_state and /snapshot/<id> read/write the REAL /tmp/snapshot-<id>-*.json
    # (the receiver hard-codes that path). Use a unique id so we never collide with a
    # real run, and clean up only the files THIS test created.
    snap_id = f"artifacttest-{os.getpid()}"
    created_jsons = []

    # Start the REAL server (plain HTTPServer; we don't need IP_FREEBIND on loopback).
    server = HTTPServer(("127.0.0.1", 0), mod.BreakoutHandler)
    port = server.server_address[1]
    base = f"http://127.0.0.1:{port}"
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()

    try:
        # 1. /health unchanged
        st, body = get(base + "/health")
        check(st == 200 and body == {"ok": True}, "/health -> 200 {ok:true}")

        # 2. /checkpoint: the sidecar's CRIU export of THIS node's app container.
        #    target_id is the workqueue app container; export_path is the host tar.
        app_tar = os.path.join(tmpdir, f"snapshot-{snap_id}-workqueue-a.tar.zst")
        st, body = post(base + "/checkpoint",
                        {"target_id": "workqueue-a", "export_path": app_tar})
        check(st == 200 and body == {"ok": True}, "/checkpoint (app CRIU) -> 200 {ok:true}")
        check(os.path.isfile(app_tar), "/checkpoint wrote the app export tar")

        # 3. /snapshot_state: persist node a's recorded Chandy-Lamport cut. The node
        #    identity is the app container id (CHECKPOINT_TARGET == workqueue-a).
        artifact_a = {
            "snapshot_id": snap_id,
            "node": "workqueue-a",
            "status": "complete",
            "peers": {
                "10.24.24.11": {"send_seq": 7, "recv_seq": 4, "messages": []},
                "10.24.24.12": {"send_seq": 3, "recv_seq": 5, "messages": []},
            },
        }
        st, body = post(base + "/snapshot_state", artifact_a)
        check(st == 200 and body == {"ok": True}, "/snapshot_state (node a cut) -> 200 {ok:true}")
        json_a = f"/tmp/snapshot-{snap_id}-workqueue-a.json"
        created_jsons.append(json_a)
        check(os.path.isfile(json_a),
              "/snapshot_state wrote /tmp/snapshot-<id>-workqueue-a.json")
        with open(json_a) as f:
            check(json.load(f)["peers"]["10.24.24.11"]["send_seq"] == 7,
                  "persisted artifact round-trips the recorded cut")

        # 4. A second node's cut lands in its own per-node file (the global cut is the
        #    union of per-node jsons; GET /snapshot/<id> globs them together).
        artifact_b = {
            "snapshot_id": snap_id,
            "node": "workqueue-b",
            "status": "complete",
            "peers": {"10.24.24.10": {"send_seq": 4, "recv_seq": 7, "messages": []}},
        }
        st, _ = post(base + "/snapshot_state", artifact_b)
        json_b = f"/tmp/snapshot-{snap_id}-workqueue-b.json"
        created_jsons.append(json_b)
        check(st == 200 and os.path.isfile(json_b),
              "/snapshot_state (node b cut) -> 200, wrote node b json")

        # 5. GET /snapshot/<id>: the restore-mode sidecar reads back EVERY node's cut.
        st, body = get(base + "/snapshot/" + snap_id)
        check(st == 200, "GET /snapshot/<id> -> 200")
        check(body.get("snapshot_id") == snap_id, "served snapshot id matches")
        got_nodes = sorted(n.get("node") for n in body.get("nodes", []))
        check(got_nodes == ["workqueue-a", "workqueue-b"],
              "GET /snapshot/<id> returns both per-node cuts")

        # 6. GET /snapshot/<unknown> -> 404 (restore aborts loudly on a missing cut)
        st, body = get(base + "/snapshot/" + snap_id + "-nope")
        check(st == 404 and body.get("ok") is False,
              "GET /snapshot/<unknown> -> 404")

        # 7. /snapshot_state rejects a path-traversal node id (no file escapes /tmp)
        st, body = post(base + "/snapshot_state",
                        {"snapshot_id": snap_id, "node": "../escape", "peers": {}})
        check(st == 400 and body.get("ok") is False,
              "traversal node id -> 400")
        check(not os.path.lexists("/tmp/escape.json"),
              "no artifact file escaped /tmp")

        # 8. /checkpoint with wrong fields -> 400
        st, body = post(base + "/checkpoint", {"target_id": "x"})
        check(st == 400, "/checkpoint with wrong fields -> 400")

        # 9. /checkpoint with a non-absolute export path -> 400 (field_ok: *_path absolute)
        st, body = post(base + "/checkpoint",
                        {"target_id": "workqueue-a", "export_path": "relative.tar"})
        check(st == 400 and body.get("ok") is False,
              "/checkpoint non-absolute export_path -> 400")

        # 10. the removed branch model is gone: its trigger endpoint is now just an
        #     unknown route, and the receiver has none of its module-level helpers.
        #     (Tokens built at runtime so this assertion file stays clean of the
        #     removed names.)
        removed_route = "/checkpoint" + "-pair"
        st, body = post(base + removed_route,
                        {"caller_id": "sidecar-a", "snapshot_id": snap_id})
        check(st == 404, "removed app+sidecar trigger endpoint is no longer a route (404)")
        check(("checkpoint" + "-pair") not in body.get("error", ""),
              "404 error no longer advertises the removed endpoint")
        for removed in ("SNAP_" + "ROOT", "checkpoint_" + "pair",
                        "resolve_" + "pair", "point_" + "latest_at"):
            check(not hasattr(mod, removed),
                  f"receiver no longer defines removed symbol {removed!r}")
    finally:
        server.shutdown()
        shutil.rmtree(tmpdir, ignore_errors=True)
        for p in created_jsons:
            try:
                os.remove(p)
            except OSError:
                pass
        # Belt-and-suspenders: remove anything our unique id created under /tmp.
        for p in glob.glob(f"/tmp/snapshot-{snap_id}-*.json"):
            try:
                os.remove(p)
            except OSError:
                pass

    if FAILURES:
        print(f"\nBREAKOUT-ARTIFACT FAIL ({len(FAILURES)} check(s) failed)")
        sys.exit(1)
    print("\nBREAKOUT-ARTIFACT PASS")
    sys.exit(0)


if __name__ == "__main__":
    main()
