# Findings — `src/counter.c` (the migrated workload) + `src/Makefile`

Severity: critical/high/medium/low/info. Confidence: how sure the reviewer is it's a real defect.

Static result: counter.c **compiles clean** under the project's `-Wall -Wextra -Werror -O2`
(see `analysis_output/10_counter_build.txt`); `gcc -fanalyzer` and cppcheck found no
memory-safety issues in it. The bugs below are logic / financial / protocol, which
those tools cannot see.

---

## C1 — Non-atomic TRANSFER destroys money on delivery failure  [HIGH, confidence high — reproduced]
**Where:** `node()` TRANSFER branch, `counter.c:192-205`.
**What:** On `TRANSFER`, the node does `counter -= amount` (line 196) then fires the
`CREDIT` to the destination with `send_udp()` (line 202) — a **fire-and-forget UDP send
with no ACK, no retry, and no rollback** — and then replies `OK TRANSFER` to the caller
(line 204) regardless of whether the credit was delivered.
**Why it's a bug:** If the CREDIT datagram is lost (UDP loss, destination down, dropped
during the migration window, or the proxy marks the destination `EXTERNAL` and drops it —
see M6/D1), the debited amount simply vanishes. The whole project asserts conservation
(`sum == 30`); this is the primary way that invariant silently breaks, yet the transfer
is reported successful.
**Trigger:** Transfer while the destination (or its sidecar) is unavailable — exactly the
condition the migration test creates.
**Evidence:** `repros/repro_counter.sh` — transferring 7 from A to a dead host drops A
to 3 with no recipient; the 7 is gone and `transfer` still printed `OK`.
**Fix:** Make the transfer a two-phase / acked protocol: only debit after the credit is
acknowledged by the receiver (or use a durable outbox with retry + idempotent apply).

## C2 — Constant transaction id `tx123` + no idempotency → double-credit / mint  [HIGH, confidence high]
**Where:** `transfer()` builds `"TRANSFER tx123 ..."` (`counter.c:251`, marked "fix later");
`node()` CREDIT handler applies every credit unconditionally (`counter.c:184-191`).
**What:** Every transfer reuses the literal `tx123`, and the CREDIT handler has **no
dedup** on the txid — it just does `counter += amount`.
**Why it's a bug:** The RUDP proxy provides *at-least-once* delivery (it retransmits
unacked packets, `mesh_proxy.py:308-317`). If an ACK is lost, the **same CREDIT is
delivered twice and applied twice** → money is created. Tunnel-level seq dedup only helps
while proxy state is intact; across a checkpoint/restore or an EXTERNAL fallback there is
no protection. Two genuinely distinct transfers are also indistinguishable.
**Fix:** Generate a unique txid per transfer and have the CREDIT handler record applied
txids (idempotent apply).

## C3 — No bounds / sign validation on amounts (negative "transfer" mints funds; overflow)  [MEDIUM, confidence high — reproduced]
**Where:** CREDIT `counter += amount` (`:186`), TRANSFER `counter -= amount` (`:196`),
`amount` parsed by `sscanf(... %d ...)`.
**What:** `amount` is a signed `int` with no validation. A **negative** transfer amount
*increases* the sender's balance and decreases the receiver's; values near `INT_MAX`
overflow (UB / wrap).
**Evidence:** `repros/repro_counter.sh` issues a negative transfer and shows the balance go up.
**Fix:** Reject non-positive amounts; bound-check against current balance and INT_MAX;
consider unsigned/checked arithmetic.

## C4 — `IPV6_V6ONLY` set on an AF_INET (IPv4) socket  [LOW, confidence high]
**Where:** `bind_udp()`, `counter.c:33`.
**What:** `setsockopt(sock, IPPROTO_IPV6, IPV6_V6ONLY, ...)` is applied to a socket created
as `AF_INET` (line 28). That option only applies to AF_INET6 sockets; on an IPv4 socket
the kernel returns an error which is **ignored** (return value unchecked).
**Why it's a bug:** Dead/incorrect code that signals confusion about the socket family.
**Fix:** Remove it (the app is IPv4-only).

## C5 — Socket-call return values ignored  [LOW, confidence high]
**Where:** `setsockopt` (`:32-33`), `sendto` in `send_reply` (`:141`) and the CREDIT
`send_udp` (`:202`).
**What:** Failures of these calls are silently dropped. The `send_reply`/`send_udp`
omissions compound C1 (a failed credit looks identical to success).
**Fix:** Check return values; at least log / propagate the credit-send failure.

## C6 — Reply accepted from any source (no validation)  [LOW–MEDIUM, confidence medium]
**Where:** `request_udp()` `recvfrom(sock, reply, BUF-1, 0, NULL, NULL)` (`counter.c:120`).
**What:** The client sends a request then accepts the **first** UDP datagram that arrives
within the timeout, with no check that it came from the host it queried.
**Why it's a bug:** A stray, delayed, or forged datagram is taken as the reply. In
`get_counter()` (`:280-294`) a forged `counter=` value corrupts the `sum` consistency
check, and a forged `OK`/`ERR` flips `transfer`/`reset` exit status.
**Fix:** `connect()` the socket or compare the source address of the reply.

## C7 — `to_int()` swallows malformed numeric input  [LOW, confidence high]
**Where:** `to_int()` `counter.c:13` (`strtol` with no error check).
**What:** A non-numeric PORT/AMOUNT silently becomes `0` (e.g. PORT 0 → kernel picks a
random port and the node listens somewhere unexpected; AMOUNT 0 → no-op transfer).
**Fix:** Validate `endptr`/`errno`.

## C8 — (verified safe) sscanf field widths vs buffers  [INFO]
Checked: `txid[128]`/`%127s`, `from[64]`/`%63s`, `host[256]`/`%255s`,
`peer_port[32]`/`%31s`, `buf[BUF]` with `recvfrom(..., sizeof(buf)-1, ...)`, and all
`snprintf`/`vsnprintf` are correctly bounded. **No buffer overflow found** in counter.c.
Recorded as a negative result so the audit is explicit.

## C9 — App never triggers the in-band snapshot path  [MEDIUM, confidence high — design]
**Where:** counter.c never sends `__START_SNAPSHOT__`; that token is only recognized by
`mesh_proxy.py:236`.
**What:** The entire Chandy-Lamport snapshot machinery in `snapshot_handler.py` is
**unreachable from the real workload** — nothing in the app or tests emits the trigger,
and the test suite uses out-of-band `podman checkpoint` instead. So that subsystem is
dead/untested in practice (and, per the S-series, broken if it ever did run).
**Fix:** Either wire the app to emit `__START_SNAPSHOT__` (and fix the S-series bugs) or
remove the dead path; document the actual checkpoint mechanism used by the tests.
