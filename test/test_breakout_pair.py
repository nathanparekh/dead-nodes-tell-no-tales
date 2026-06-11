#!/usr/bin/env python3
"""Offline logic test for proxy/breakout_receiver.py's /checkpoint-pair endpoint.

No podman, no CRIU, no containers: we put a fake `sudo`/`podman` on PATH that
simulates `podman inspect` (caller name), `podman ps` (running names), and
`podman container checkpoint` (touches the export tar), then drive the REAL
HTTP server. Asserts pair resolution, the /tmp/snapshots/<id>/<name>.tar.zst
export layout, the atomic `latest` symlink, and that the pre-existing
/checkpoint, /health and validation behaviour are untouched.

Run: python3 test/test_breakout_pair.py   -> prints "BREAKOUT-PAIR PASS" / exit 0
"""

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


def install_fake_podman(bindir, running_names):
    """Write fake `sudo` and `podman` shims.

    podman inspect --format {{.Name}} <id>  -> "/<id>"  (running name == id here)
    podman ps --format {{.Names}}           -> running_names, newline-joined
    podman container checkpoint <name> -e <path> ...  -> touch <path>, rc 0
    sudo <argv...>                          -> exec argv (transparent)
    """
    podman = os.path.join(bindir, "podman")
    with open(podman, "w") as f:
        f.write(
            "#!/usr/bin/env python3\n"
            "import sys, os\n"
            f"RUNNING = {running_names!r}\n"
            "a = sys.argv[1:]\n"
            "if a[:1] == ['inspect']:\n"
            "    cid = a[-1]\n"
            "    print('/' + cid)\n"
            "elif a[:1] == ['ps']:\n"
            "    print('\\n'.join(RUNNING))\n"
            "elif a[:2] == ['container', 'checkpoint']:\n"
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
    snap_root = os.path.join(tmpdir, "snapshots")
    os.makedirs(snap_root)
    mod.SNAP_ROOT = snap_root  # redirect exports away from the real /tmp/snapshots

    bindir = os.path.join(tmpdir, "bin")
    os.makedirs(bindir)
    # Running pair: app `workqueue-a` + sidecar `sidecar-a` (suffix -a).
    install_fake_podman(bindir, ["workqueue-a", "sidecar-a", "workqueue-b", "sidecar-b"])
    os.environ["PATH"] = bindir + os.pathsep + os.environ["PATH"]

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

        # 2. /checkpoint-pair happy path: caller is the sidecar, resolves to app+sidecar
        snap_id = "11111111-2222-3333-4444-555555555555"
        st, body = post(base + "/checkpoint-pair",
                        {"caller_id": "sidecar-a", "snapshot_id": snap_id})
        check(st == 200 and body.get("ok") is True, "/checkpoint-pair -> 200 ok")
        check(body.get("containers") == ["workqueue-a", "sidecar-a"],
              "pair resolved app-first then sidecar (workqueue-a, sidecar-a)")

        snap_dir = os.path.join(snap_root, snap_id)
        app_tar = os.path.join(snap_dir, "workqueue-a.tar.zst")
        side_tar = os.path.join(snap_dir, "sidecar-a.tar.zst")
        check(os.path.isfile(app_tar), "export layout: <id>/workqueue-a.tar.zst")
        check(os.path.isfile(side_tar), "export layout: <id>/sidecar-a.tar.zst")

        latest = os.path.join(snap_root, "latest")
        check(os.path.islink(latest) and os.path.realpath(latest) == os.path.realpath(snap_dir),
              "latest symlink points at the snapshot dir")

        # 3. caller given as the APP resolves the same pair (app-first ordering preserved)
        snap_id2 = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        st, body = post(base + "/checkpoint-pair",
                        {"caller_id": "workqueue-a", "snapshot_id": snap_id2})
        check(st == 200 and body.get("containers") == ["workqueue-a", "sidecar-a"],
              "caller=app also resolves (workqueue-a, sidecar-a)")
        check(os.path.realpath(latest) == os.path.realpath(os.path.join(snap_root, snap_id2)),
              "latest atomically repointed to the newest snapshot")

        # 4. snapshot_id with a path traversal is rejected by field_ok (400, no dir made)
        st, body = post(base + "/checkpoint-pair",
                        {"caller_id": "sidecar-a", "snapshot_id": "../escape"})
        check(st == 400 and body.get("ok") is False, "traversal snapshot_id -> 400")
        check(not os.path.exists(os.path.join(snap_root, "..", "escape")) and
              not os.path.lexists(os.path.join(tmpdir, "escape")),
              "no export escaped SNAP_ROOT")

        # 5. wrong fields -> 400
        st, body = post(base + "/checkpoint-pair",
                        {"target_id": "x", "export_path": "/tmp/x"})
        check(st == 400, "/checkpoint-pair with wrong fields -> 400")

        # 6. ambiguous/missing partner -> 400 (suffix -z has no running partner)
        st, body = post(base + "/checkpoint-pair",
                        {"caller_id": "sidecar-z", "snapshot_id": "00000000-0000-0000-0000-000000000000"})
        check(st == 400 and "partner" in body.get("error", ""),
              "no running partner -> 400 with explanatory error")

        # 7. pre-existing single /checkpoint route still works (counter test depends on it)
        single = os.path.join(tmpdir, "single.tar.zst")
        st, body = post(base + "/checkpoint",
                        {"target_id": "workqueue-b", "export_path": single})
        check(st == 200 and body == {"ok": True}, "/checkpoint (single) -> 200 {ok:true}")
        check(os.path.isfile(single), "/checkpoint wrote the single export")

        # 8. unknown endpoint lists both route families
        st, body = post(base + "/nope", {"x": 1})
        check(st == 404 and "checkpoint-pair" in body.get("error", ""),
              "unknown POST -> 404 mentioning /checkpoint-pair")
    finally:
        server.shutdown()
        shutil.rmtree(tmpdir, ignore_errors=True)

    if FAILURES:
        print(f"\nBREAKOUT-PAIR FAIL ({len(FAILURES)} check(s) failed)")
        sys.exit(1)
    print("\nBREAKOUT-PAIR PASS")
    sys.exit(0)


if __name__ == "__main__":
    main()
