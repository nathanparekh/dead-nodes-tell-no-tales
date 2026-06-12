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
| `../proxy/breakout_receiver.py` | each host, as root | HTTP `10.99.0.1:8989`; podman lifecycle API. The app's snapshot handler drives `POST /checkpoint` (CRIU image, `--leave-running`) and `POST /snapshot_state` (channel-state cut) per node; restore uses `POST /restore` + `POST /run_sidecar` (restore-mode sidecar) |
| `node_ctl.sh` | each host, as root (piped over ssh) | per-host ops: start/health-check the receiver, netem on/off, kill, restore, trigger snapshot |
| `wait_inflight.py` | inside a vlan container | exits 0 the moment the token is committed to the A->B wire |
| `demo_token_ring.sh` | one host (the driver) | the whole experiment, stages 1–9 |

## The artifact snapshot/restore flow (and why the demo needs it)

Restore is **artifact-based** (main's snapshot/restore system). A snapshot, keyed by a
caller-chosen `snapshot_id`, writes per node two files to `/tmp` on that node's own host:
`/tmp/snapshot-<sid>-tokenring-<x>.tar.zst` (the app's CRIU image) and
`/tmp/snapshot-<sid>-tokenring-<x>.json` (its Chandy-Lamport channel-state cut). The
channel cut — per-peer `send_seq`/`recv_seq` plus the recorded in-flight messages — is the
durable copy of the recording, so the demo can kill the containers and still replay later.

Restore CRIU-restores each app, then starts a **restore-mode sidecar** (the receiver's
`/run_sidecar`, which sets `RESTORE_SNAPSHOT_ID=<sid>` and `CHECKPOINT_TARGET=tokenring-<x>`).
That sidecar's `restore_from_artifact()` GETs `/snapshot/<sid>`, finds this node's entry,
seeds the per-peer seqs, and replays the recorded channel into the restored app **once** in
seq order before serving live traffic. The CRIU-only control instead starts a *plain*
sidecar (no `RESTORE_SNAPSHOT_ID`), so nothing is replayed and the ring violates.

Two supporting pieces:

1. **Breakout bridge for the host call.** The sidecar POSTs to the host's breakout receiver
   at `http://10.99.0.1:8989`. The host is
   unreachable by name from a macvlan child interface, so `build_tokenring.sh` attaches a
   dedicated podman bridge network `breakout` (subnet 10.99.0.0/24, gateway 10.99.0.1) to
   any app container that carries a sidecar and passes `-e BREAKOUT_URL` to the sidecar.
   The receiver binds the gateway IP (IP_FREEBIND) so the bridge is the reachable path.
2. **Markers go to ALL peers** (textbook Chandy-Lamport), including back to the peer the
   marker came from. With an "all except sender" rule the initiator — whose marker
   reaches both other nodes first — never gets a marker back, never terminates, never
   writes its channel artifact, and silently consumes every later message on its recorded
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

The breakout receiver replaces the old standalone host checkpoint agent and the macvlan
shim it needed. `node_ctl.sh receiver-up` creates the `breakout` bridge network (if missing) and starts
`proxy/breakout_receiver.py` on `10.99.0.1:8989` as root; `demo_token_ring.sh`'s preflight
calls it for you on every host. To do it by hand:

```sh
# from a repo checkout on each host (idempotent; logs to /var/log/breakout_receiver.log)
sudo bash harness/node_ctl.sh receiver-up
curl -sf 10.99.0.1:8989/health        # -> {"ok": true}

# after deploying (next section), confirm the SIDECAR can reach the receiver:
sudo podman exec sidecar-<x> wget -qO- http://10.99.0.1:8989/health
```

`build_tokenring.sh` attaches the `breakout` bridge to each sidecar-carrying app container
and passes `-e BREAKOUT_URL=http://10.99.0.1:8989`, so the sidecar reaches the host over
the bridge (a macvlan child interface cannot reach the parent host directly — that is the
whole reason for the breakout bridge). The receiver's `run_sidecar` (used by
`node_ctl.sh restore`) passes the same `BREAKOUT_URL` so restored sidecars keep that path.

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
`LOSS_TIMEOUT_MS=60000` (must match deployment),
`VERIFY_ROUNDS=30`, `BREAKOUT_GW=10.99.0.1` (receiver on port 8989).

`NETEM_MS` is the race the whole demo hinges on: the delayed token must still be on the
A->B wire when C's marker reaches B, and that marker leaves C only after ssh + `podman
exec` (the trigger) **plus C's blocking CRIU checkpoint** (1-3s; the receiver log
timestamps show exactly how long). The 5000ms default clears that comfortably; the in-order
tunnel guarantees the closing marker still sorts after the token, so a bigger delay only
costs wall-clock time.

Milestone ladder (plan §11):

- **M3** — `--resting`: no netem; snapshot while the token *rests* in a node; restore (a)
  only; expect PASS. Pure plumbing check of receiver -> CRIU -> restore -> replay.
- **M4+M5+M6** — no flags: the full experiment, both restores.
- **`--criu-only`** — skips restore (a); just demonstrates the violation.

## What each stage does / expected output

1. **preflight** — start + health-check the breakout receiver (`/health`) on all hosts,
   `tokenring-<x>`/`sidecar-<x>` Up, baseline `verify` PASS. Warns loudly if a node was
   deployed without `LOSS_TIMEOUT_MS`.
2. **netem-on** — `tc netem delay ${NETEM_MS}ms` on A's traffic to B (inside `sidecar-a`).
3. **position + trigger** — `wait_inflight` watches A and B; the instant the token is on
   the A->B wire, `T_SNAP` is recorded (the loss-timer baseline) and C (the node
   "behind" the token) sends `__START_SNAPSHOT__`.
4. **collect** — polls (`has-snapshot`) until every node's CRIU image **and** channel-state
   cut (`/tmp/snapshot-<sid>-tokenring-<x>.{tar.zst,json}`) exist on all 3 hosts, then
   netem-off and reads each node's channel-cut JSON (B's appears only once A's
   netem-delayed marker lands, so it is the last to complete).
5. **bite check** — B's cut must contain a recorded `TOKEN ...` payload (in some peer's
   `channel`), i.e. the token was captured as *channel state*, invisible to CRIU. Aborts
   (ring left running) if not.
6. **kill** — `podman rm -f` all six containers.
7. **restore (a)** — restore all apps from their CRIU images, then start restore-mode
   sidecars (`RESTORE_SNAPSHOT_ID=<sid>`) which replay each node's recorded channel from
   its artifact; `verify` -> expect **PASS**; kill again.
8. **restore (b)** — restore the CRIU images, bring up *plain* sidecars (no replay); wait
   out `LOSS_TIMEOUT_MS` (+5s grace);
   nodes regenerate a stale-epoch token; `verify` -> expect **FAIL** (duplicate epoch).
9. **summary** — expected-vs-got table; exit 0 iff every executed restore matched.

The demo leaves restore (b)'s violated ring running for inspection; redeploy a clean ring
with `build_tokenring.sh` (token-less nodes first) afterwards.

## Troubleshooting

- **Bite check fails** ("no TOKEN in B's channel state"): the marker race lost — the token
  reached B's app before C's marker did. `NETEM_MS` must exceed the trigger latency
  (ssh + `podman exec`) **plus** the initiator's blocking checkpoint; the receiver log
  (`/var/log/breakout_receiver.log`) timestamps show how long the checkpoint took. Raise it,
  e.g. `NETEM_MS=8000 ./harness/demo_token_ring.sh`. Nothing was killed; just re-run.
- **Restore (a) FAILs and `podman logs tokenring-*` shows `REGENERATE` lines**: the
  kill->restore+replay gap exceeded `LOSS_TIMEOUT_MS`. CRIU does **not** virtualize
  `time.time()`, so restored nodes see all the wall-clock time that passed and fire their
  loss timers. Redeploy with a larger `LOSS_TIMEOUT_MS` (and pass the same value to the
  driver). The driver warns when the gap eats into the budget.
- **Stage 4 times out** (no checkpoints appear): the sidecar couldn't reach the breakout
  receiver. Check `/var/log/breakout_receiver.log`, confirm the receiver answers on
  `10.99.0.1:8989/health`, and re-run the `wget` reachability test from the setup section
  (the app container must have the `breakout` bridge attached — `build_tokenring.sh` does
  this only when a sidecar is deployed).
- **Starting a fresh sidecar on a live (non-restored) node**: don't. The old sidecar's
  TPROXY rules live in the *app's* netns and survive `podman rm -f sidecar-x`, so the
  replacement exits at boot (`ip route add ... File exists`) and the node goes dark on
  the mesh while `podman run -d` still reports success. `node_ctl.sh restore` /
  `restore-criu-only` start a sidecar only right after a CRIU restore (fresh netns); to
  recycle a live node's sidecar, redeploy the node.
- **criu/podman notes**: checkpoint/restore needs root podman and criu installed
  (`sudo podman container checkpoint --leave-running ...` must work by hand, cf.
  `cmds.sh`). `--leave-running` is required — a stop-checkpoint tears down the app's
  netns mid-marker, killing the sidecar's snapshot protocol. Restore keeps the
  container's name and IP; `node_ctl.sh restore` removes any same-named container first.
- **Artifacts**: per node, on its own host, the app's snapshot handler writes the CRIU
  image at `/tmp/snapshot-<sid>-tokenring-<x>.tar.zst` and the channel-state cut at
  `/tmp/snapshot-<sid>-tokenring-<x>.json` (the receiver serves the cut via
  `GET /snapshot/<sid>`; the restore-mode sidecar reads it back to replay). The driver
  also copies each cut into a temp dir it deletes on exit (for the bite check).
