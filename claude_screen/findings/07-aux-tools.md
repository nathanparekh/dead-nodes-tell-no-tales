# Findings — auxiliary tools (`redis_client.py`, `tcp-howto.c`, `chat.py`, `udp_script.py`)

These are demo/benchmark utilities, not on the migration path, but were audited too.

---

## A1 — `tcp-howto.c`: inverted `inet_aton` return check (bad address undetected)  [MEDIUM, confidence high]
**Where:** `tcp-howto.c:121-125`.
**What:** `inet_aton()` returns **0 on failure, non-zero on success**. The code tests
`if (ret < 0)` (never true) instead of `if (ret == 0)`, so an invalid IP is not detected
and `connect()` proceeds with a zero/garbage `sin_addr`.
**Fix:** `if (ret == 0) { ... }`.

## A2 — `tcp-howto.c`: raw `int` over the wire + unchecked read/write  [LOW, confidence high]
**Where:** `:135-137`. Sends/receives a bare `int` with no byte-order/size normalization
(breaks across endianness/word size), and ignores `read`/`write` return values (partial
4-byte transfers unhandled). Demo-only.

## A3 — `tcp-howto.c`: unused `argc` params → fails `-Wall -Wextra -Werror`  [LOW, confidence high]
**Where:** `:45`, `:107`. `gcc` reports `-Wunused-parameter`
(`analysis_output/11_tcphowto_build.txt`). The Makefile only builds `counter.c`, so this
isn't compiled in the normal flow; but adding it under the project's flags would break the
build.
**Fix:** `(void)argc;` or remove the unused parameter.

## A4 — `redis_client.py`: stale client never closed on outage → fd/connection leak  [LOW, confidence medium]
**Where:** `redis_client.py:320` recreates `client = make_client(args)` on every failed op
but never `client.close()`/`connection_pool.disconnect()` on the old one.
**Why it's a bug:** During a prolonged outage (one new client per retry) sockets/pools
accumulate.
**Fix:** Close the old client before recreating.

## A5 — `redis_client.py`: GET result not validated; None counts as OK  [LOW, confidence low]
**Where:** `timed_get` (`:184-194`) returns `Status.OK` regardless of value; a missing key
(None) is still "OK". For a benchmark this is acceptable; flagged as a correctness caveat
if it's meant to verify round-trips.

## A6 — `redis_client.py` `_percentile`: (checked) interpolation is fine  [INFO]
**Where:** `:94-100`. Linear-interpolated nearest-rank; `hi` is clamped to `n-1`, handles
`n==1`. No off-by-one found. Recorded as a checked item.

## A7 — `chat.py`: bare `except:` hides real errors; close/recv thread race  [LOW, confidence high]
**Where:** `chat.py:13` (`except:` swallows everything to break on close) and `:51`
(`sock.close()` in the main thread while the daemon `receive_messages` may be mid
`recvfrom`).
**Fix:** Catch `OSError`; signal the thread to stop before closing.

## A8 — `udp_script.py`: `--send` and `--recv` not mutually validated  [INFO, confidence high]
**Where:** `udp_script.py:14-38`. If both flags are given, only `--send` runs (elif); if
neither, it prints a joke and exits 0 (no non-zero status for misuse). Minor.
