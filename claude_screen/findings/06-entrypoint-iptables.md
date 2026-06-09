# Findings — `proxy/entrypoint.sh` (TPROXY/iptables) + `proxy/config.py`

---

## N1 — Non-idempotent network setup under `set -e` → proxy won't start on restart  [MEDIUM → LOW, see 10-correctness-audit.md]
> **AUDIT: overstated.** Real under `set -e`, but no tested path hits it — CRIU restore and
> `podman start` don't re-run the entrypoint, and `rm`+`run` gives a fresh netns. Triggers
> only on a non-standard manual re-invocation over a persistent netns. Downgrade to low.
**Where:** `entrypoint.sh:2` (`set -e`), `:15-18` (`ip rule add`, `ip route add local`,
two `iptables -A` appends).
**Why it's a bug:** On a container restart (same netns reused) or any second run, `ip rule
add`/`ip route add` fail with `RTNETLINK ... File exists`, and `iptables -A` silently
stacks duplicate rules each run. With `set -e`, the first EEXIST aborts the script and the
final `exec python mesh_proxy.py` (`:20`) never runs — the proxy is dead on restart.
(A CRIU *restore* re-injects the already-running process so the script isn't re-run, which
masks this for the restore path but not for ordinary restarts.)
**Fix:** Make rules idempotent: check-before-add (`ip rule … || true`, `iptables -C … ||
iptables -A …`), or flush first.

## N2 — Subnet auto-detection can pick the wrong interface  [LOW–MEDIUM, confidence medium]
**Where:** `entrypoint.sh:4-11` — `ip route | grep -v default | awk '{print $1}' | head -n1`.
**Why it's a bug:** It takes the *first* non-default route, which may be a podman bridge or
an unrelated subnet rather than the mesh subnet → TPROXY marks the wrong traffic (or none).
Mitigated when `MESH_SUBNET` is passed via `-e` (`build.sh` does), but `run_chat_*.sh`,
`run_recv.sh`, `run_send.sh` do **not** pass it, so they rely on this fragile detection.
`$DETECTED_SUBNET` is also unquoted (SC2086).
**Fix:** Require `MESH_SUBNET` explicitly, or detect by matching the configured mesh CIDR.

## N3 — Hardcoded Linux socket-option numbers are arch/portability-fragile  [LOW, confidence medium]
**Where:** `config.py:17-20` (`IP_RECVORIGDSTADDR=20`, `IP_TRANSPARENT=19`, `SO_MARK=36`,
`SO_REUSEPORT=15`).
**Why it's a bug:** These literals are correct on mainline Linux but bypass Python's own
`socket` constants (e.g. `socket.SO_REUSEPORT`, `socket.IP_TRANSPARENT` exist on modern
Pythons) and would be silently wrong on a platform where the numbers differ. Hardcoding
invites drift.
**Fix:** Prefer `getattr(socket, "IP_TRANSPARENT", 19)` etc.; document the Linux dependency.

## N4 — No teardown of iptables/ip rules; STOPSIGNAL SIGKILL precludes cleanup  [INFO, confidence high]
**Where:** `Containerfile.rudp` `STOPSIGNAL SIGKILL`; `entrypoint.sh` installs rules but has
no trap/cleanup.
**Why it matters:** Rules persist in a reused netns and compound with N1. For throwaway
containers this is acceptable; flagged for completeness.

## N6 — Env-driven iptables scope vs hardcoded proxy mesh subnet diverge  [HIGH, confidence high]
Cross-ref **M13**: `entrypoint.sh` configures the TPROXY iptables rules from
`$MESH_SUBNET` (env / auto-detected), but `mesh_proxy.py` decides mesh membership from the
**hardcoded** `config.MESH_SUBNET`. The two can disagree, so the kernel intercepts traffic
the proxy then treats as `EXTERNAL` (or the reverse). Fix in `config.py`: read the env var.

## N7 — TPROXY hairpin for locally-originated packets may not intercept as intended  [→ FALSE POSITIVE / unverified, see 10-correctness-audit.md]
> **AUDIT: no evidence it fails.** Nothing in the code proves the hairpin doesn't work, and
> the rest of the analysis assumes interception *does* fire. Keep as a "verify on a real node
> with tcpdump" item, not a confirmed bug.
**Where:** `entrypoint.sh:15-18`. The design marks locally-generated UDP in `mangle OUTPUT`
(mark 1), routes mark-1 via `ip rule fwmark 1 table 100` (local route on `lo`), expecting it
to re-enter `PREROUTING` where the `-m mark --mark 1` TPROXY rule fires.
**Why it's flagged:** TPROXY is normally applied to *forwarded/inbound* traffic in
PREROUTING; capturing **locally-originated** traffic this way is a non-standard hairpin that
depends on the fwmark surviving the loopback re-route and on the app actually sending to the
mesh IPs (not loopback). If the mark doesn't persist into PREROUTING, the app's packets are
never delivered to the proxy on :9000 at all. This needs a live tcpdump/`iptables -t mangle
-L -v` check on a real node to confirm; flagged as potential per recall policy.
**Fix:** Verify on a node; the conventional approach is `-m socket`/`-j TPROXY` on inbound
plus a separate divert chain — confirm the local-origin path works end-to-end.

## N5 — (checked) PROXY_MARK=99 loop-exemption appears correct  [INFO]
The OUTPUT mangle rule marks mesh-bound UDP with mark 1 **unless** mark==99
(`entrypoint.sh:17`), and the proxy sets `SO_MARK=99` on its tunnel and spoof sockets
(`mesh_proxy.py:171,179,223`), so proxy-originated traffic is not re-intercepted. Incoming
tunnel packets on 9001 carry mark 0 and aren't matched by the PREROUTING `--mark 1` rule,
so they reach the tunnel socket normally. This part looks correct — recorded as a checked
item. (Caveat: the bind-fallback path M7 still sets SO_MARK=99, so it stays exempt.)
