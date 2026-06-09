# Findings — security & robustness

Severities are rated for a **research prototype** but all issues are flagged. Several are
"by design (research)" but worth stating because the project models a financial system.

---

## SEC1 — RUDP tunnel has no authentication, integrity, or encryption  [HIGH, confidence high]
**Where:** `mesh_proxy.py` `TunnelProtocol` (`:26-136`), tunnel socket on 0.0.0.0:9001
(`:221-224`).
**What:** Any host that can reach UDP/9001 can inject `__PROBE__`, data packets, ACKs, and
(once S4 is fixed) markers. There is no shared secret, MAC, or sequence authentication.
**Impact:** A remote attacker can forge tunnel data that the proxy will deliver to the
local app with a **spoofed source IP** (`IP_TRANSPARENT`, `:170`), forge ACKs to suppress
retransmits, or replay packets. Combined with SEC2 this allows minting/resetting balances
from off-host.
**Fix:** Add an HMAC over each packet with a per-mesh key; consider DTLS/WireGuard for the
tunnel.

## SEC2 — The counter app trusts any UDP source (no auth on RESET/TRANSFER/CREDIT)  [HIGH, confidence high — reproduced]
**Where:** `counter.c` `node()` (`:179-216`).
**What:** Anyone who can send a UDP datagram to the node can `RESET` the balance to any
value, `CREDIT` (mint) arbitrary amounts, or `TRANSFER`.
**Evidence:** `repros/repro_counter.sh` resets A to 999999 and uses a negative transfer to
inflate the balance — no credentials.
**Fix:** Authenticate/authorize messages (signed commands, allow-list of peers).

## SEC3 — Crafted-packet faults & unbounded-memory DoS  [MEDIUM, confidence medium]
**Where:** `mesh_proxy.py` `_handle_local_intercept`/`TunnelProtocol`; see M3, M4, M9, M10.
**What:** Malformed ancillary data or packets that trip the snapshot bugs raise unhandled
exceptions that escape the reader callback (M3/M9). Auto-created peers and unbounded
`recv_buffer`/`probe_buffer`/`unacked` (M4/M10) let a remote sender exhaust memory.
**Fix:** Validate all lengths before unpack; bound every per-peer structure; rate-limit.

## SEC4 — Proxy will spoof ANY source IP to the local app on attacker's behalf  [MEDIUM, confidence medium]
**Where:** `get_spoof_sock` binds the source from the tunnel header with `IP_TRANSPARENT`
(`:157-181`, used at `:191`,`:303`); the header's TargetIP/SrcPort are attacker-controlled
(no auth, SEC1).
**What:** This turns the sidecar into a source-spoofing oracle on the local host, defeating
any source-IP-based trust the app might use.
**Fix:** Authenticate the tunnel (SEC1); restrict spoofable sources to known mesh peers.

## SEC5 — Test harness runs `--privileged` with the host root podman socket mounted  [LOW, confidence high]
**Where:** `run_test_suite.sh:19-26` (`--privileged`, `-v /run/podman/podman.sock:...:rw`),
`Containerfile.tests` (`CONTAINER_HOST=...podman.sock`).
**What:** Full host control from inside the test container (needed for CRIU, but a large
blast radius). A compromised test image/input → host compromise.
**Fix:** Scope down where possible; document the trust requirement.

## SEC6 — Unauthenticated checkpoint trigger over plain HTTP  [LOW, confidence high]
**Where:** `snapshot_handler.py:100-109` POSTs to
`http://host.containers.internal:9090/checkpoint` with no TLS/auth, body derived from
`gethostname()` (S9).
**Fix:** Authenticate the agent channel; validate the container id.
