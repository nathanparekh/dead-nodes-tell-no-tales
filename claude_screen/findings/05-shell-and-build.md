# Findings — shell scripts, Containerfiles, build & reproducibility

Cross-checked with `shellcheck` (`analysis_output/20_shellcheck.txt`).

> **POST-MERGE / AUDIT STATUS (see `09-merge-impact.md`, `10-correctness-audit.md`):**
> **B1, B2** (prebuilt-binary COPY, cross-arch) are **fixed** — the images now COPY+run
> `counter.py`. **B3** (udp-counter name collision) is a **false positive** now — `build.sh`
> builds `counter`/`sidecar`. **B7, B8** are **obsolete** — `test_without_proxy/` was deleted.
> **B6** is **relocated** to `run_test_suite.sh:19-36` (still real). **B4, B5, B9–B12 hold**.
> **B13** is a doc nit. The text below is the original (pre-merge) analysis.

---

## B1 — Images COPY a prebuilt `src/counter` that nothing builds and that is absent  [HIGH, confidence high]
**Where:** `Containerfile:9`, `Containerfile.tests:17`, `test_without_proxy/Containerfile:2`
all `COPY src/counter ...`; `build.sh`/`run_test_suite.sh` only run `podman build` — **no
`make`**. `src/counter` is gitignored (`.gitignore:1`) and is **not present** in the repo.
**Why it's a bug:** `podman build` fails with `COPY src/counter: no such file or directory`
until someone manually runs `make -C src`. The build is not self-contained/reproducible.
**Fix:** Use a multi-stage Containerfile that compiles `counter.c` from source, or have the
build scripts run `make` first.

## B2 — Cross-arch hazard: a host-built binary won't exec in the Linux container  [HIGH, confidence high]
**Where:** same COPY-prebuilt pattern as B1; dev host is macOS/arm64.
**Why it's a bug:** Running `make` on macOS produces a Mach-O (or otherwise host-targeted)
binary; copied into `debian:bookworm-slim` it fails at runtime with "exec format error".
Even on Linux, arch must match the container. Copying a host binary into an image is the
wrong pattern.
**Fix:** Compile inside the image (build stage with gcc), guaranteeing the right
OS/arch/libc.

## B3 — `udp-counter` image-name collision (C app vs python script)  [MEDIUM, confidence high]
**Where:** root `Containerfile` builds `udp-counter` = the C counter; `proxy/build.sh:3`
builds `udp-counter` from `proxy/Containerfile.app`, which packages **`udp_script.py`**
(a python UDP tool), not the C app.
**Why it's a bug:** Whichever build ran last wins the tag. `build.sh`/tests expect
`udp-counter` to be the C app; running `proxy/build.sh` silently replaces it with the
python tool (different ENTRYPOINT/args) → confusing, hard-to-debug failures.
**Fix:** Give the images distinct names.

## B4 — `run_recv.sh`/`run_send.sh` use a non-existent image and an incompatible entrypoint  [MEDIUM, confidence high]
**Where:** `proxy/run_recv.sh:4`, `proxy/run_send.sh:2` run image **`udp-tester`**;
`proxy/build.sh` builds `udp-test`, `udp-counter`, `rudp-sidecar` — there is no
`udp-tester`. Moreover the `udp-test` image (`Containerfile.test`) runs **chat.py**, which
does not accept `--recv`/`--send` (those are `udp_script.py` flags, packaged only as the
`udp-counter`/Containerfile.app image).
**Why it's a bug:** Both scripts fail to start (unknown image), and even with the right
image name the entrypoint wouldn't accept the args.
**Fix:** Point them at the image that actually runs `udp_script.py`, with a consistent name.

## B5 — `run_chat_b.sh` first line typo `udo` + missing shebang  [MEDIUM, confidence high]
**Where:** `proxy/run_chat_b.sh:1` — `udo podman rm ...` (missing `s`); the file has no
`#!/bin/bash` (shellcheck SC2148).
**Why it's a bug:** `udo: command not found`; the cleanup is skipped. (No `set -e`, so it
limps onward, leaving stale containers that can break the next run.)
**Fix:** `sudo` + add a shebang.

## B6 — `run_test_proxycontainer.sh`: sidecar attaches after the `--rm -it` container is gone, and `$MESH_SUBNET` is unbound  [MEDIUM, confidence high]
**Where:** `run_test_proxycontainer.sh:19-27` runs the test container `--rm -it`
(foreground, blocking, auto-removed on exit); `:31-36` then tries
`--network container:test-container` — but with `--rm` that container no longer exists.
Also `set -euo pipefail` (`:3`) + `-e MESH_SUBNET="$MESH_SUBNET"` (`:35`) where
`MESH_SUBNET` is **never defined** → "unbound variable" aborts the script.
**Why it's a bug:** The proxy-attached test path cannot work as written (ordering + unbound
var). Two distinct defects.
**Fix:** Run the test container detached with a stable name, attach the sidecar before/while
it runs, and define `MESH_SUBNET`.

## B7 — Port inconsistency: 5000 vs 9000 across the repo  [LOW–MEDIUM, confidence high]
**Where:** `build.sh:37` runs the node on **5000**; tests use `PORT=5000`
(`tests/test_local_b.sh:6`); but `test_without_proxy/build.sh:24` runs on **9000** and
`README.md` documents `9000`. `proxy/run_chat_*.sh` use 5000/6000.
**Why it's a bug:** Deploying via `test_without_proxy/build.sh` (port 9000) makes the
port-5000 tests unable to reach the node → spurious failures.
**Fix:** Pick one port; parameterize consistently.

## B8 — `test_without_proxy/build.sh` container-name/IP contract differs from `build.sh`  [LOW, confidence medium]
**Where:** `test_without_proxy/build.sh:24` names the container `counter-"$CONTAINER_NAME"`
and derives the IP from the **first char of `$CONTAINER_NAME`**, while `build.sh` takes a
*suffix* and computes from that. Passing the wrong style double-prefixes (`counter-counter-a`)
or computes the wrong IP.
**Fix:** Unify the CLI contract across the two build scripts.

## B9 — `build.sh` runs `sudo podman rm -fa` (removes ALL host containers)  [LOW, confidence high]
**Where:** `build.sh:11`. Destroys every container on the host, not just this app's.
**Fix:** Remove only the named app/sidecar containers.

## B10 — Scripts assume a pre-created `vlan` macvlan network  [LOW, confidence high]
**Where:** every `--network vlan...` (`build.sh:36`, `run_chat_*.sh`, `run_test_suite.sh:20`).
Nothing in the repo creates `vlan`; `--network vlan:ip=...` fails if it doesn't exist.
**Fix:** Add a `podman network create` step / document the prerequisite.

## B11 — `run_test_suite.sh` leaks a background `podman system service`  [INFO, confidence high]
**Where:** `run_test_suite.sh:10-15` starts `sudo podman system service ... &` with
`--time=0` (never times out) and never stops it.
**Fix:** Track and clean up the PID, or document it.

## B12 — Misc shell hygiene (shellcheck)  [LOW]
Unquoted expansions SC2086 (`build.sh:49 $SIDECAR_NAME`, `entrypoint.sh:10
$DETECTED_SUBNET`); unused vars SC2034 (`B_CONTAINER` `tests/test_local_b.sh:9`,
`B_RESTORE_NAME` `test_without_proxy/test_local_b.sh:13`, `MESH_SUBNET`
`build-without-proxy.sh:23`); `cmds.sh` is a doc with no shebang (SC2148) and the
`sudo ... > /tmp/...` redirects are not run as root (SC2024) — the documented checkpoint
commands write the tarball as the *calling* user, which can fail under sudo-only perms.

## B13 — `cmds.sh` live-migration example mixes compression extensions/flags  [LOW → DOC NIT, see 10-correctness-audit.md]
> **AUDIT: overstated.** `cmds.sh` is non-executing documentation and podman doesn't infer
> compression from the file extension. Doc nit only.
**Where:** `cmds.sh:14-20`. Pre-checkpoint exports `.tar.zst`, post exports `.tar.gz`
(`--export /tmp/post.tar.gz`), and restore mixes `--import`/`--import-previous`. Not
obviously wrong but the inconsistent extensions/flags are error-prone; verify the
`--pre-checkpoint`/`--with-previous` lineage matches podman's expected ordering.
