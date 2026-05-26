#!/usr/bin/env python3
"""
Redis benchmark: continuously GET/SET a key, measure latency per op,
track a rolling history, and handle intermittent server unavailability.

Usage:
    python redis_bench.py [--host HOST] [--port PORT] [--key KEY]
                          [--delay SECONDS] [--history N] [--retry-delay SECONDS]
                          [--timeout SECONDS] [--db N] [--password PW]
                          [--report-every N]
"""

import argparse
import signal
import statistics
import sys
import time
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from typing import Deque, Optional

try:
    import redis
except ImportError:
    print("redis-py not found.  Install with: pip install redis")
    sys.exit(1)


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------


class Status(str, Enum):
    OK = "OK"
    ERROR = "ERR"
    TIMEOUT = "TIMEOUT"


@dataclass
class Sample:
    iteration: int
    timestamp: float  # Unix epoch (seconds)
    op: str  # "SET" or "GET"
    status: Status
    latency_ms: Optional[float]  # None on error/timeout
    error_msg: Optional[str] = None


@dataclass
class History:
    max_size: int
    samples: Deque[Sample] = field(default_factory=deque)

    def add(self, sample: Sample):
        self.samples.append(sample)
        if len(self.samples) > self.max_size:
            self.samples.popleft()

    def latencies(self, op: Optional[str] = None) -> list[float]:
        return [
            s.latency_ms
            for s in self.samples
            if s.latency_ms is not None and (op is None or s.op == op)
        ]

    def error_count(self) -> int:
        return sum(1 for s in self.samples if s.status != Status.OK)

    def ok_count(self) -> int:
        return sum(1 for s in self.samples if s.status == Status.OK)

    def success_rate(self) -> float:
        total = len(self.samples)
        return (self.ok_count() / total * 100) if total else 0.0

    def stats(self, op: Optional[str] = None) -> dict:
        lats = self.latencies(op)
        if not lats:
            return {}
        return {
            "n": len(lats),
            "min": min(lats),
            "max": max(lats),
            "mean": statistics.mean(lats),
            "p50": statistics.median(lats),
            "p95": _percentile(lats, 95),
            "p99": _percentile(lats, 99),
        }


def _percentile(data: list[float], pct: float) -> float:
    if not data:
        return 0.0
    sorted_data = sorted(data)
    k = (len(sorted_data) - 1) * pct / 100
    lo, hi = int(k), min(int(k) + 1, len(sorted_data) - 1)
    return sorted_data[lo] + (sorted_data[hi] - sorted_data[lo]) * (k - lo)


# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------

RESET = "\033[0m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[31m"
CYAN = "\033[36m"
BOLD = "\033[1m"
DIM = "\033[2m"


def color_latency(ms: float) -> str:
    if ms < 5:
        return f"{GREEN}{ms:6.2f}ms{RESET}"
    if ms < 25:
        return f"{YELLOW}{ms:6.2f}ms{RESET}"
    return f"{RED}{ms:6.2f}ms{RESET}"


def color_status(status: Status) -> str:
    if status == Status.OK:
        return f"{GREEN}OK     {RESET}"
    if status == Status.TIMEOUT:
        return f"{YELLOW}TIMEOUT{RESET}"
    return f"{RED}ERR    {RESET}"


def fmt_stats(stats: dict) -> str:
    if not stats:
        return "  (no data)"
    return (
        f"  n={stats['n']}  "
        f"min={stats['min']:.2f}ms  "
        f"mean={stats['mean']:.2f}ms  "
        f"p50={stats['p50']:.2f}ms  "
        f"p95={stats['p95']:.2f}ms  "
        f"p99={stats['p99']:.2f}ms  "
        f"max={stats['max']:.2f}ms"
    )


def print_report(history: History, iteration: int, outage_s: Optional[float]):
    print(f"\n{BOLD}{CYAN}{'='*72}{RESET}")
    print(
        f"{BOLD}  Benchmark report  |  iteration {iteration}  |  {datetime.now().strftime('%H:%M:%S')}{RESET}"
    )
    print(f"{CYAN}{'='*72}{RESET}")
    total = len(history.samples)
    print(f"  Window:       last {total} samples")
    print(
        f"  Success rate: {history.success_rate():.1f}%  "
        f"({history.ok_count()} ok / {history.error_count()} errors)"
    )
    if outage_s is not None:
        print(f"  {YELLOW}Server currently UNREACHABLE for {outage_s:.1f}s{RESET}")
    print(f"\n  {BOLD}SET latency:{RESET}{fmt_stats(history.stats('SET'))}")
    print(f"  {BOLD}GET latency:{RESET}{fmt_stats(history.stats('GET'))}")
    print(f"  {BOLD}ALL latency:{RESET}{fmt_stats(history.stats())}")
    print(f"{CYAN}{'='*72}{RESET}\n")


# ---------------------------------------------------------------------------
# Timed wrappers
# ---------------------------------------------------------------------------


def timed_set(
    client: redis.Redis, key: str, value: str
) -> tuple[Status, Optional[float], Optional[str]]:
    t0 = time.perf_counter()
    try:
        client.set(key, value)
        return Status.OK, (time.perf_counter() - t0) * 1000, None
    except redis.TimeoutError as e:
        return Status.TIMEOUT, (time.perf_counter() - t0) * 1000, str(e)
    except redis.RedisError as e:
        return Status.ERROR, None, str(e)


def timed_get(
    client: redis.Redis, key: str
) -> tuple[Status, Optional[float], Optional[str], Optional[str]]:
    t0 = time.perf_counter()
    try:
        val = client.get(key)
        return Status.OK, (time.perf_counter() - t0) * 1000, None, val
    except redis.TimeoutError as e:
        return Status.TIMEOUT, (time.perf_counter() - t0) * 1000, str(e), None
    except redis.RedisError as e:
        return Status.ERROR, None, str(e), None


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def parse_args():
    p = argparse.ArgumentParser(
        description="Redis GET/SET benchmark with latency history"
    )
    p.add_argument(
        "--host", default="localhost", help="Redis host (default: localhost)"
    )
    p.add_argument("--port", type=int, default=6379, help="Redis port (default: 6379)")
    p.add_argument("--password", default=None, help="Redis password")
    p.add_argument("--db", type=int, default=0, help="Redis DB index (default: 0)")
    p.add_argument(
        "--key", default="bench:key", help="Key to GET/SET (default: bench:key)"
    )
    p.add_argument(
        "--delay",
        type=float,
        default=0.0,
        help="Sleep between iterations in seconds (default: 0)",
    )
    p.add_argument(
        "--history",
        type=int,
        default=500,
        help="Rolling history window size (default: 500)",
    )
    p.add_argument(
        "--retry-delay",
        type=float,
        default=1.0,
        help="Seconds to wait between retries when server is down (default: 1)",
    )
    p.add_argument(
        "--timeout",
        type=float,
        default=2.0,
        help="Socket timeout in seconds (default: 2)",
    )
    p.add_argument(
        "--report-every",
        type=int,
        default=50,
        help="Print full report every N iterations (default: 50)",
    )
    return p.parse_args()


def make_client(args) -> redis.Redis:
    return redis.Redis(
        host=args.host,
        port=args.port,
        password=args.password,
        db=args.db,
        decode_responses=True,
        socket_connect_timeout=args.timeout,
        socket_timeout=args.timeout,
    )


def main():
    args = parse_args()
    history = History(max_size=args.history)

    print(f"\n{BOLD}Redis Benchmark{RESET}  {args.host}:{args.port}  key={args.key!r}")
    print(
        f"timeout={args.timeout}s  retry-delay={args.retry_delay}s  "
        f"history={args.history}  report-every={args.report_every}"
    )
    print(f"Press {BOLD}Ctrl+C{RESET} to stop and see final report.\n")

    client = make_client(args)

    running = True
    outage_start: Optional[float] = None  # time.monotonic() when server went away

    def handle_signal(sig, frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    iteration = 0

    while running:
        iteration += 1
        ts = time.time()
        value = f"iter={iteration} ts={datetime.now(timezone.utc).isoformat()}"

        # --- SET ---
        set_status, set_ms, set_err = timed_set(client, args.key, value)
        history.add(Sample(iteration, ts, "SET", set_status, set_ms, set_err))

        # --- GET ---
        get_status, get_ms, get_err, _ = timed_get(client, args.key)
        history.add(Sample(iteration, ts, "GET", get_status, get_ms, get_err))

        # --- Determine whether we are currently in an outage ---
        op_ok = set_status == Status.OK and get_status == Status.OK

        if not op_ok:
            if outage_start is None:
                outage_start = time.monotonic()
                print(
                    f"\n{RED}{BOLD}[{iteration:>8}] Server unreachable -- outage started{RESET}"
                )

            outage_s = time.monotonic() - outage_start
            err_detail = set_err or get_err or "unknown error"

            # Print one line showing the outage duration
            print(
                f"  [{iteration:>8}]  "
                f"SET {color_status(set_status)}  "
                f"GET {color_status(get_status)}  "
                f"outage={YELLOW}{outage_s:.1f}s{RESET}  {DIM}{err_detail[:60]}{RESET}"
            )

            # Recreate the client (clears stale socket state)
            client = make_client(args)
            time.sleep(args.retry_delay)

        else:
            if outage_start is not None:
                outage_s = time.monotonic() - outage_start
                print(
                    f"\n{GREEN}{BOLD}[{iteration:>8}] Server back!  outage lasted {outage_s:.1f}s{RESET}\n"
                )
                outage_start = None

            set_col = color_latency(set_ms)
            get_col = color_latency(get_ms)
            print(
                f"[{iteration:>8}]  "
                f"SET {set_col}  "
                f"GET {get_col}  "
                f"{DIM}ok={history.ok_count()} err={history.error_count()} "
                f"win={len(history.samples)}{RESET}"
            )

            if args.delay > 0:
                time.sleep(args.delay)

        # --- Periodic full report ---
        if iteration % args.report_every == 0:
            outage_s_now = (time.monotonic() - outage_start) if outage_start else None
            print_report(history, iteration, outage_s_now)

    # Final report
    print_report(history, iteration, None)
    print(f"Benchmark stopped after {iteration} iteration(s).\n")


if __name__ == "__main__":
    main()
