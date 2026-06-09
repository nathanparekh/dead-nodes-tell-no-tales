# Merge impact assessment — `4d1336c` (main → bug-hunt-claude-screen)

A set of commits was merged in on 2026-06-09 (`04a12da reorganize dirs`, `7e28eca delete
old cont files`, `b7db86f move container files`, `6b8b178 update cont paths`,
`5845784 switch to .py counter`, `fb8da86 stupid containers`, `3e943b8 change permissions`).
This note records their effect on the findings in `00-summary.md` and the per-component files.

## What changed (source)
- **`src/counter.c` → `src/counter.py`** (new 209-line Python rewrite; `counter.c` is still
  in the tree but is now **dead** — the images and tests use `counter.py`).
- **Containerfiles renamed/relocated:** root `Containerfile`→`Containerfile.counter`
  (now `COPY src/counter.py` + run it), `Containerfile.tests`→`Containerfile.test`,
  and a root `Containerfile.rudp` (copies the **unchanged** `proxy/*.py`). Sidecar image is
  now built as **`sidecar`**, app image as **`counter`** (was `udp-counter`).
- **`tests/` → `test/`**; `test/test_local_b.sh` now calls `./counter.py`.
- **Deleted:** `build-without-proxy.sh`, `run_test_proxycontainer.sh`, and the entire
  `test_without_proxy/` directory.
- **`build.sh` / `run_test_suite.sh`** updated for the new image names; `README.md` trimmed
  to just the node IPs.
- **`proxy/` is UNCHANGED** (mesh_proxy.py, snapshot_handler.py, config.py, entrypoint.sh,
  and the proxy/Containerfile.* / run_*.sh are byte-for-byte the same).

## Bottom line
**The merge does not invalidate the review.** The proxy is the source of the most severe
defects (S-series, M-series) and is untouched, so **all of `02-mesh-proxy.md`,
`03-snapshot-handler.md`, `04-distributed-correctness.md`, `06-entrypoint-iptables.md`,
`07-aux-tools.md`, and `08-security.md` stand verbatim.** The rewrite fixed a few
build/packaging issues and one C-only bug, made integer-overflow moot, **relocated** one
script bug, and **carried over every financial/auth defect** into `counter.py` — re-proven
at runtime (`repros/output/repro_counter_py.txt`).

---

## Effect on each finding

### Unaffected (proxy/ untouched) — still valid as written
- **All M1–M14** (`02-mesh-proxy.md`) — proxy code identical. `repro_snapshot_bugs.py` still
  imports `proxy/` and still reproduces S1/S2/S4/S5/S7.
- **All S1–S11** (`03-snapshot-handler.md`).
- **D1–D6** (`04-distributed-correctness.md`) — `test/test_local_b.sh` keeps the identical
  flow (remove `counter-b`+`sidecar-b`, then transfer A→B), so D1's "credit dropped, not
  queued" still holds; D2/D3 (shared-netns ordering; checkpoint omits `--tcp-established`
  while restore uses it) are unchanged.
- **N1–N7** (`06-entrypoint-iptables.md`) — `proxy/entrypoint.sh` + `config.py` unchanged;
  M13/N6 (`MESH_SUBNET` env ignored by the proxy) still applies.
- **A1–A8** (`07-aux-tools.md`) — those files are untouched.
- **SEC1, SEC3, SEC4, SEC6** (proxy/tunnel) unchanged. **SEC5** (privileged test container +
  podman.sock) still present in `run_test_suite.sh`.

### Carried over into `counter.py` (re-confirmed at runtime)
| old | now | counter.py:line | status |
|-----|-----|-----------------|--------|
| C1 non-atomic transfer destroys money | same | 70, 74, 77 | **carried-over** — reproduced |
| C2 constant `tx123` + no CREDIT dedup | same | 99; 52-61 | **carried-over** |
| C3 negative amount mints funds | same | 68, 70 | **carried-over** — reproduced |
| C3b no insufficient-funds check (negative balance) | same | 70 | **carried-over** |
| C5 send errors ignored | same/worse | 74; 88-89 | **carried-over** (now swallowed by a blanket except) |
| C6 reply accepted from any source | same | 32 | **carried-over** |
| C9 app never emits `__START_SNAPSHOT__` | same | (none) | **carried-over** (snapshot path still dead) |
| C10 recvfrom busy-loop | same/worse | 44-89 | **carried-over** (blanket except spins on any error) |
| SEC2 no auth on RESET/TRANSFER/CREDIT | same | 49-87 | **carried-over** — reproduced (unauth RESET 999999) |

### Fixed by the rewrite
- **C4** (`IPV6_V6ONLY` on an AF_INET socket) — **fixed**: `counter.py` `bind_udp` sets only
  `SO_REUSEADDR` (`:14`).
- **B1** (images `COPY` a prebuilt binary that nothing compiles, gitignored & absent) —
  **fixed**: `Containerfile.counter`/`Containerfile.test` now `COPY src/counter.py` and run it
  directly; no compile step needed.
- **B2** (cross-arch: host-built binary can't exec in the Linux container) — **fixed/moot**:
  Python is interpreted; no arch-specific artifact.
- **B7** (port 5000 vs 9000 inconsistency) and **B8** (name/IP contract mismatch) —
  **fixed**: the offending `test_without_proxy/build.sh` was deleted; everything now uses 5000.

### Made moot by Python semantics
- The **integer-overflow** halves of **C3** and **C3b** (INT_MAX wrap on `counter`/`total`):
  Python integers are arbitrary precision → **moot**. (The negative-amount / negative-balance
  halves remain — see carried-over.)

### Relocated (not fixed)
- **B6** (sidecar attaches to a `--rm -it` container that has already exited; `$MESH_SUBNET`
  unbound under `set -u`) — the file `run_test_proxycontainer.sh` was deleted, but the **same
  two bugs moved into `run_test_suite.sh:19-36`**: the test container runs `--rm -it`
  (foreground) and the `sidecar-test` attach happens only after it exits and is removed; and
  `-e MESH_SUBNET="$MESH_SUBNET"` references an undefined variable (`set -euo pipefail` →
  "unbound variable"). New: `run_test_suite.sh` also references image **`sidecar`** which it
  never builds (only `build.sh` builds it).

### Changed in character
- **C7** (`to_int` silently returns 0 on bad input) → `counter.py` uses `int(...)` which
  **raises**; in `node()` the exception is caught by the blanket `except` and the message is
  silently **dropped** (no reply) instead of mis-parsed as 0. Different failure mode, still a
  robustness gap.

### Carried over unchanged (scripts not touched by the merge)
- **B3** udp-counter name collision — root no longer uses `udp-counter` (now `counter`), so
  the root-vs-proxy collision is gone; **but `proxy/Containerfile.app` still builds an image
  literally named `udp-counter` from `udp_script.py`** (mislabel remains). **Downgraded** to low.
- **B4** (`run_recv.sh`/`run_send.sh` reference non-existent `udp-tester`; `udp-test` runs
  chat.py which rejects `--recv/--send`), **B5** (`run_chat_b.sh` `udo` typo + no shebang),
  **B9** (`build.sh` `sudo podman rm -fa` nukes all host containers), **B10** (assumes a
  pre-created `vlan` macvlan network), **B11** (leaked `podman system service`), **B13**
  (`cmds.sh` live-migration flags) — all **carried over** (those files were not updated by the
  merge; `build.sh:11` still has `rm -fa`).

### New (introduced by the rewrite)
- **CP1 — blanket `except Exception: pass` around the whole `node()` loop** (`counter.py:88-89`).
  Swallows decode errors, send failures, `int()` parse errors, and genuine bugs; turns a
  persistent `recvfrom` error into a tight CPU spin; and makes truncated known commands
  (`len(parts)` check fails) silently send no reply. [MEDIUM]
- **CP2 — `./counter.py` relative invocation** (`test/test_local_b.sh:12+`,
  `Containerfile.test` ENTRYPOINT) depends on cwd being the WORKDIR (`/test`); works as wired
  but fragile. [LOW]
- **README gutted** — the build/run instructions (how to use `build.sh`, the per-node setup)
  were removed; only node IPs remain, worsening B10's "undocumented prerequisites." [LOW]

## Independent re-eval confirmation
A second, independent multi-agent pass reviewed only the merged changes (raw output:
`_merge_reeval_raw.json`, 26 findings / 19 confirmed). It agreed with this assessment on
every point — carried-over C1/C2/C3/SEC2/C6/C9/D1/D2/D3, fixed C4/B1/B2, relocated B6 — and
sharpened a few items:
- **CP1 is worse than "medium":** the blanket `except` is really *two* defects — (a) it
  masks decode/send/parse errors and busy-spins, and (b) **truncated/malformed known
  commands (`len(parts)` check fails) get no reply at all**, breaking request-reply symmetry
  so the client just times out. Re-rated **high**.
- **CP3 (carried over):** `recvfrom(BUF=512)` silently truncates datagrams >512 B (same as
  the C version). Low/medium.
- **B4 refinement (post-rename):** `build.sh` now builds images `counter`/`sidecar`, but the
  **`proxy/` run scripts were not updated** — `run_chat_a.sh`/`run_chat_b.sh` still use
  `udp-test` (only built by `proxy/build.sh`), and `run_recv.sh`/`run_send.sh` still use the
  never-built `udp-tester`. The two build systems' image names have diverged further.
- **`run_test_suite.sh` also references image `sidecar` it never builds** (only `build.sh`
  builds it) — in addition to the relocated B6 bugs.
- Checked-OK: `Containerfile.counter` (WORKDIR `/app`) vs `Containerfile.test` (WORKDIR
  `/test`) both copy+run `counter.py` consistently within their own container — not a bug.
- One verifier rated the `run_test_suite.sh` unbound-`$MESH_SUBNET` item a false positive;
  direct reading says it *is* unbound under `set -euo pipefail`, so it's kept (recall).

## New evidence
- `repros/output/repro_counter_py.txt` — runs the **actual deployed `counter.py`** and shows:
  a 7-unit transfer to a dead host destroys the funds (A: 10→3, exit 0/"OK"), an
  unauthenticated `reset` to 999999, and a negative transfer inflating the balance.
- `analysis_output/33_pylint_errors_src.txt` / `31_pyflakes.txt` — `counter.py` is lint-clean
  (no errors); the bugs are logic/financial, invisible to linters (as before).
