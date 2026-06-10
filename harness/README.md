# Token-ring checkpoint demo — runbook

The experiment (TOKEN_RING_PLAN.md §9): take ONE Chandy-Lamport snapshot while the
token is **in flight** on the A->B hop, kill every node, then restore twice from the
**same** CRIU images:

- **(a) with** the proxy-recorded channel state replayed -> `verify` **PASS**
- **(b) CRIU memory only**, no replay -> the nodes' naive loss-recovery regenerates a
  token with a stale epoch -> `verify` **FAIL** (duplicate epoch — mutual exclusion violated)

If (a) passes and (b) fails, the checkpoint provably depends on the proxy's channel state.

## What's in this directory

| file | runs where | purpose |
|---|---|---|
| `checkpoint_agent.py` | each host, as root | HTTP `:9090/checkpoint`; CRIU-checkpoints the app container (`--leave-running`) into `$SNAP_DIR/<sid>/` |
| `node_ctl.sh` | each host, as root (piped over ssh) | per-host ops: netem on/off, kill, restore, fetch channel JSON, trigger snapshot |
| `wait_inflight.py` | inside a vlan container | exits 0 the moment the token is committed to the A->B wire |
| `replay_channels.py` | inside a vlan container | re-sends recorded in-flight messages into a restored node |
| `demo_token_ring.sh` | one host (the driver) | the whole experiment, stages 1–9 |

## Four small proxy changes (and why the demo needs them)

1. **Channel-state persistence.** `_finish_global_snapshot` replays recorded in-flight
   messages into the *live* app and then **clears** `channel_states` — replay-then-clear
   consumes the recording. Our demo kills the containers after the snapshot, so the
   in-memory copy is gone exactly when we need it. The patch dumps the recording to
   `/tmp/channel_states_<sid>.json` inside the sidecar *before* replaying (always, even
   when empty). That JSON is the only durable copy the harness can replay after restore.
2. **`CHECKPOINT_AGENT_URL` override.** The sidecar POSTs to
   `http://host.containers.internal:9090/checkpoint`; on a macvlan network that name can
   be unreachable. The env var lets you point it somewhere reachable (see the macvlan
   shim below).
3. **Marker wire-framing fix.** Markers are now sent with the same 17-byte header as
   data packets (`!BQHH4s`); the old 9-byte header was unparseable by the receiving
   tunnel, so no snapshot could ever complete.
4. **Markers go to ALL peers** (textbook Chandy-Lamport), including back to the peer the
   marker came from. With the old "all except sender" rule the initiator — whose marker
   reaches both other nodes first — never got a marker back, never terminated, never
   wrote its channel JSON, and silently consumed every later message on its recorded
   channels (killing the live ring after a snapshot).

## Prerequisites

- 3 Linux hosts (README.md: A=172.31.34.109, B=172.31.32.239, C=172.31.47.64), each with
  podman + criu installed and the macvlan network `vlan` configured. Create it with an
  `--ip-range` that excludes the static node IPs, e.g.
  `podman network create -d macvlan -o parent=<if> --subnet 10.24.24.0/24 --ip-range 10.24.24.128/26 vlan`
  — otherwise podman's IPAM cursor will eventually hand a one-shot helper container a
  *remote* node's 10.24.24.10/.11/.12 (duplicate IP on the shared L2).
- This repo cloned on **each** host; ssh (with passwordless sudo) from the driver host to
  the other two — the driver pipes `node_ctl.sh` over `ssh ... sudo bash -s`.
- Images built on each host: `build_tokenring.sh` builds both `tokenring` and `sidecar`.
  The driver host also uses the `tokenring` image for one-shot `status`/`verify`/replay
  containers, so deploy (or at least build) there too.

## One-time per-host setup

```sh
# 1. start the checkpoint agent as root (nohup or a tmux pane).
#    The sh -c matters: a bare `sudo ... > /var/log/...` would do the redirect
#    as your unprivileged user and die with "Permission denied".
sudo sh -c 'nohup python3 harness/checkpoint_agent.py > /var/log/checkpoint_agent.log 2>&1 &'
curl -sf localhost:9090/health        # -> ok

# 2. after deploying (next section), confirm the SIDECAR can reach the agent:
sudo podman exec sidecar-<x> wget -qO- http://host.containers.internal:9090/health
```

If that `wget` hangs/fails (common on macvlan), first try
`-e CHECKPOINT_AGENT_URL=http://<this host's LAN IP>:9090/checkpoint` on the sidecar's
`podman run` line. On macvlan that usually fails the **same** way — the kernel never
delivers frames between a macvlan child interface and the parent's host stack, no matter
which host IP you aim at. The standard fix is a macvlan **shim** interface on each host
(pick a unique mesh-subnet IP per host, outside the node range, e.g. A=.251 B=.252 C=.253;
`<parent-if>` is the interface the `vlan` network was created on, e.g. `ens5`):

```sh
sudo ip link add ckpt0 link <parent-if> type macvlan mode bridge
sudo ip addr add 10.24.24.251/24 dev ckpt0     # .252 on B, .253 on C
sudo ip link set ckpt0 up
```

Then run the sidecar with `-e CHECKPOINT_AGENT_URL=http://10.24.24.251:9090/checkpoint`
(the agent already listens on 0.0.0.0, so it answers on the shim address). Add the env
var in `build_tokenring.sh` *and* in `node_ctl.sh`'s `sidecar-up` so restored sidecars
get it too.

## Deploy the ring

Order matters: **token-less nodes first, the HAS_TOKEN node LAST** — the boot token is
forwarded `HOLD_MS` (~500ms) after start and is lost forever if the successor isn't up.
`LOSS_TIMEOUT_MS` is **mandatory on every node** for the M5/M6 punchline: without it,
restore (b) never regenerates a token and "fails safe" instead of failing unsafely.

```sh
# host C:  LOSS_TIMEOUT_MS=60000 ./build_tokenring.sh c C 0
# host B:  LOSS_TIMEOUT_MS=60000 ./build_tokenring.sh b B 0
# host A:  LOSS_TIMEOUT_MS=60000 ./build_tokenring.sh a A 1
```

(`build_tokenring.sh` tails the sidecar logs; Ctrl-C out — the containers keep running.)

## Running the demo

From a repo checkout on any one host (empty `*_SSH` = "that node is this host"):

```sh
export B_SSH="ssh ubuntu@172.31.32.239" C_SSH="ssh ubuntu@172.31.47.64"   # driver on host A
./harness/demo_token_ring.sh --resting     # M3
./harness/demo_token_ring.sh               # M4+M5+M6
./harness/demo_token_ring.sh --criu-only   # control only
```

Knobs (env): `A_IP/B_IP/C_IP` (10.24.24.10/.11/.12), `PORT=5000`, `NETEM_MS=5000`,
`LOSS_TIMEOUT_MS=60000` (must match deployment), `SNAP_DIR=/var/lib/tokenring-demo`,
`VERIFY_ROUNDS=30`, `AGENT_PORT=9090`.

`NETEM_MS` is the race the whole demo hinges on: the delayed token must still be on the
A->B wire when C's marker reaches B, and that marker leaves C only after ssh + `podman
exec` (the trigger) **plus C's blocking CRIU checkpoint** (1-3s; the agent log timestamps
show exactly how long). The 5000ms default clears that comfortably; the in-order tunnel
guarantees the closing marker still sorts after the token, so a bigger delay only costs
wall-clock time.

Milestone ladder (plan §11):

- **M3** — `--resting`: no netem; snapshot while the token *rests* in a node; restore (a)
  only; expect PASS. Pure plumbing check of agent -> CRIU -> restore -> replay.
- **M4+M5+M6** — no flags: the full experiment, both restores.
- **`--criu-only`** — skips restore (a); just demonstrates the violation.

## What each stage does / expected output

1. **preflight** — agent `/health` on all hosts, `tokenring-<x>`/`sidecar-<x>` Up,
   baseline `verify` PASS. Warns loudly if a node was deployed without `LOSS_TIMEOUT_MS`.
2. **netem-on** — `tc netem delay ${NETEM_MS}ms` on A's traffic to B (inside `sidecar-a`).
3. **position + trigger** — `wait_inflight` watches A and B; the instant the token is on
   the A->B wire, `T_SNAP` is recorded (the loss-timer baseline) and C (the node
   "behind" the token) sends `__START_SNAPSHOT__`.
4. **collect** — polls until one snapshot id has checkpoint tarballs on all 3 hosts, then
   netem-off, fetches each sidecar's channel JSON (polling B's briefly — it appears only
   once A's netem-delayed marker lands).
5. **bite check** — B's JSON must contain a recorded `TOKEN ...` payload, i.e. the token
   was captured as *channel state*, invisible to CRIU. Aborts (ring left running) if not.
6. **kill** — `podman rm -f` all six containers.
7. **restore (a)** — restore all apps from the tarballs, restart sidecars, replay each
   node's channel JSON at its mesh IP; `verify` -> expect **PASS**; kill again.
8. **restore (b)** — restore only, no replay; wait out `LOSS_TIMEOUT_MS` (+5s grace);
   nodes regenerate a stale-epoch token; `verify` -> expect **FAIL** (duplicate epoch).
9. **summary** — expected-vs-got table; exit 0 iff every executed restore matched.

The demo leaves restore (b)'s violated ring running for inspection; redeploy a clean ring
with `build_tokenring.sh` (token-less nodes first) afterwards.

## Troubleshooting

- **Bite check fails** ("no TOKEN in B's channel state"): the marker race lost — the token
  reached B's app before C's marker did. `NETEM_MS` must exceed the trigger latency
  (ssh + `podman exec`) **plus** the initiator's blocking checkpoint; the agent log
  timestamps show how long the checkpoint took. Raise it, e.g.
  `NETEM_MS=8000 ./harness/demo_token_ring.sh`. Nothing was killed; just re-run.
- **Restore (a) FAILs and `podman logs tokenring-*` shows `REGENERATE` lines**: the
  kill->restore+replay gap exceeded `LOSS_TIMEOUT_MS`. CRIU does **not** virtualize
  `time.time()`, so restored nodes see all the wall-clock time that passed and fire their
  loss timers. Redeploy with a larger `LOSS_TIMEOUT_MS` (and pass the same value to the
  driver). The driver warns when the gap eats into the budget.
- **Stage 4 times out** (no checkpoints appear): the sidecar couldn't reach the agent.
  Check the agent log, then the `host.containers.internal` reachability test above; set
  up the macvlan shim + `CHECKPOINT_AGENT_URL` override from the one-time setup section.
- **`node_ctl.sh sidecar-up` on a live (non-restored) node**: don't. The old sidecar's
  TPROXY rules live in the *app's* netns and survive `podman rm -f sidecar-x`, so the
  replacement exits at boot (`ip route add ... File exists`) and the node goes dark on
  the mesh while `podman run -d` still reports success. `sidecar-up` is only valid right
  after `restore` (fresh netns); to recycle a live node's sidecar, redeploy the node.
- **criu/podman notes**: checkpoint/restore needs root podman and criu installed
  (`sudo podman container checkpoint --leave-running ...` must work by hand, cf.
  `cmds.sh`). `--leave-running` is required — a stop-checkpoint tears down the app's
  netns mid-marker, killing the sidecar's snapshot protocol. Restore keeps the
  container's name and IP; `node_ctl.sh restore` removes any same-named container first.
- **Artifacts**: checkpoint tarballs at `$SNAP_DIR/<sid>/tokenring-<x>.tar.zst` on each
  host; the authoritative channel dump at `/tmp/channel_states_<sid>.json` inside each
  sidecar (the driver fetches copies into a temp dir it deletes on exit).
