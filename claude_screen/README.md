# `claude_screen` — bug-hunt results

Exhaustive bug review of the **dead-nodes-tell-no-tales** project (CRIU/Podman
checkpoint-restore migration of a stateful UDP counter app behind a TPROXY+RUDP mesh
proxy). Every tracked file was read in full; findings were cross-checked by an independent
multi-agent pass and by in-container static analysis, and the most important crashers were
**reproduced at runtime**.

Start with **`findings/00-summary.md`**.

## Layout
```
claude_screen/
├── README.md                  ← you are here
├── ASSUMPTIONS.md             ← scope, environment & methodology assumptions
├── findings/
│   ├── 00-summary.md          ← master table + headline issues  (READ FIRST)
│   ├── 01-counter-app.md      ← src/counter.c            (C1–C10)
│   ├── 02-mesh-proxy.md       ← proxy/mesh_proxy.py      (M1–M14)
│   ├── 03-snapshot-handler.md ← proxy/snapshot_handler.py(S1–S11)  ← most broken
│   ├── 04-distributed-correctness.md  ← end-to-end       (D1–D6)
│   ├── 05-shell-and-build.md  ← scripts/Containerfiles   (B1–B13)
│   ├── 06-entrypoint-iptables.md ← TPROXY + config       (N1–N7)
│   ├── 07-aux-tools.md        ← redis/tcp-howto/chat/udp (A1–A8)
│   ├── 08-security.md         ← SEC1–SEC6
│   ├── 09-merge-impact.md     ← effect of the post-review merge (C→Python rewrite + reorg)
│   ├── 10-correctness-audit.md← adversarial self-review: false positives / overstated / obsolete
│   ├── 11-snapshot-divergence.md← git root-cause: mesh_proxy changes never ported to snapshot_handler (S1–S5)
│   ├── _workflow_raw.{md,json}← raw 100-agent output (traceability)
│   ├── _correctness_audit_raw.{md,json}← raw audit-pass output
│   └── _completeness_critic.md
├── harness/                   ← reproducible static-analysis containers
│   ├── Containerfile.tools    ← gcc/clang/cppcheck/shellcheck
│   ├── Containerfile.pytools  ← pyflakes/pylint/mypy/vulture
│   ├── analyze_c.sh / analyze_py.sh
│   └── run.sh                 ← build images + run, repo mounted read-only
├── analysis_output/           ← captured tool output (counter.c builds clean, etc.)
└── repros/                    ← runtime proofs
    ├── repro_snapshot_bugs.py ← 5 proxy/snapshot crashers (no root/sockets)
    ├── repro_counter.sh       ← counter.c value-conservation / auth defects
    ├── repro_counter_py.sh    ← same defects in the post-merge counter.py
    ├── run_repros.sh          ← runs all three in containers
    └── output/                ← captured repro output (all defects CONFIRMED)
```

## Reproduce everything (from the repo root)
All tooling runs **inside containers** (nothing installed on the host) and needs only
`podman` (a Linux VM on macOS is fine):

```bash
# 1. Static analysis (C/shell + Python). Output -> claude_screen/analysis_output/
./claude_screen/harness/run.sh

# 2. Runtime proofs. Output -> claude_screen/repros/output/
./claude_screen/repros/run_repros.sh
```

Expected highlights:
- `analysis_output/10_counter_build.txt` → counter.c builds clean under `-Wall -Wextra -Werror -O2`.
- `repros/output/repro_snapshot_bugs.txt` → `5/5 defects reproduced` (S1, S2, S4, S5, S7).
- `repros/output/repro_counter.txt` → A debits 7 to a dead host and loses it; unauth RESET
  to 999999; negative transfer inflates the balance.

## How findings are rated
- **Severity:** critical / high / medium / low / info.
- **Confidence / verdict:** manual confidence plus an independent agent verdict
  (`confirmed` / `likely` / `potential` / `false_positive`). Per the task, recall is
  favored — `potential`/`false_positive` items are **kept and labeled**, not deleted.
- Negative results (things checked and found *correct*) are recorded explicitly:
  C8 (no buffer overflow in counter.c), A6 (percentile math), N5 (mark exemption), D6.

See `ASSUMPTIONS.md` for the one thing not done: a live multi-node CRIU + macvlan + TPROXY
end-to-end run (needs real Linux nodes); the D-series is reasoned from code, with D1
grounded in the EXTERNAL-routing path (M6).
