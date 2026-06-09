# Assumptions & methodology

## What this review covers
Every tracked file in the repo was read in full: `src/` (counter.c, redis_client.py,
tcp-howto.c, Makefile), `proxy/` (mesh_proxy.py, snapshot_handler.py, config.py,
entrypoint.sh, chat.py, udp_script.py, all Containerfiles and run_*.sh),
all root + `tests/` + `test_without_proxy/` shell scripts and Containerfiles,
README.md, cmds.sh, .gitignore.

## Recall bias (per the task)
Findings favor **recall over precision**: a plausible bug is flagged even when it
might turn out to be benign. Each finding carries a **confidence** and, where a
sub-agent re-checked it, a **verdict** (`confirmed` / `likely` / `potential` /
`false_positive`). Nothing is discarded; `false_positive`/`potential` items are
kept and labeled so a human can decide.

## Environment assumptions
- Host is macOS (darwin) on **arm64**; `podman` 5.8.2 with a Linux **arm64** VM.
  Containers therefore run Linux/arm64. This matters for the cross-arch build
  finding (B2).
- The project is intended to run on Linux AWS nodes A/B/C over a podman **macvlan**
  network named `vlan` (subnet 10.24.24.0/24). That network is assumed to be
  pre-created out-of-band; nothing in the repo creates it (B10).
- CRIU is assumed installed in the host kernel/podman (required for
  `podman container checkpoint/restore`). Not verifiable here; flagged where relevant.
- A real checkpoint agent at `http://host.containers.internal:9090/checkpoint`
  is assumed by snapshot_handler.py but **does not exist in the repo**.
- No external software was installed on the host. All compilers/linters/repros run
  **inside containers** (see `harness/` and `repros/`), reproducible from the repo root.

## Tools used (all in-container, see harness/)
- C: `gcc -Wall -Wextra -Werror -O2`, `gcc -fanalyzer`, `clang --analyze`, `cppcheck --enable=all`.
- Python: `py_compile`, `pyflakes`, `pylint -E`/full, `mypy`, `vulture`.
- Shell: `shellcheck`.
- Runtime repros: `repros/repro_snapshot_bugs.py` (proxy crashers, no root/sockets),
  `repros/repro_counter.sh` (counter value-conservation/auth, compiles & runs the app).

## Key limitation
A full end-to-end migration test (macvlan + TPROXY + CRIU checkpoint/restore across
nodes) was **not run**: it needs multi-node Linux hosts with NET_ADMIN, a macvlan
parent interface, and CRIU — not reproducible on this single dev box. Distributed
findings (D-series) are derived by tracing the code; the most important one (D1) is
additionally argued from the EXTERNAL-routing code path (M6). Logic-level crashers
(S1, S2, C-series) ARE reproduced at runtime in containers.
