#!/usr/bin/env python3
import sys
import socket
import time

BUF = 512

def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)

def bind_udp(port):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(('', int(port)))
    return sock

def send_udp(host, port, msg):
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.sendto(msg.encode('utf-8'), (host, int(port)))
        sock.close()
        return 0
    except Exception:
        return -1

def request_udp(host, port, msg, timeout_ms):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.sendto(msg.encode('utf-8'), (host, int(port)))
        sock.settimeout(timeout_ms / 1000.0)
        data, addr = sock.recvfrom(BUF)
        sock.close()
        return data.decode('utf-8')
    except Exception:
        sock.close()
        return None

def coordinator(name, port, worker_args):
    workers = []
    for i in range(0, len(worker_args), 2):
        workers.append((worker_args[i], worker_args[i + 1]))
    rr_cursor = 0
    done_tally = 0
    seen_done = set()
    sock = bind_udp(port)
    print(f"coordinator {name} listening on udp/{port} with workers={workers}", flush=True)

    while True:
        try:
            data, addr = sock.recvfrom(BUF)
            buf = data.decode('utf-8')

            if buf.startswith("SUBMIT "):
                parts = buf.split()
                if len(parts) >= 2:
                    jobid = parts[1]
                    w_host, w_port = workers[rr_cursor]
                    rr_cursor = (rr_cursor + 1) % len(workers)
                    send_udp(w_host, w_port, f"JOB {jobid}")
                    print(f"{name} SUBMIT job={jobid} -> {w_host}:{w_port}", flush=True)
            elif buf.startswith("DONE "):
                parts = buf.split()
                if len(parts) >= 3:
                    jobid = parts[1]
                    worker_name = parts[2]
                    if jobid in seen_done:
                        print(f"{name} DONE job={jobid} from={worker_name} duplicate", flush=True)
                    else:
                        seen_done.add(jobid)
                        done_tally += 1
                        print(f"{name} DONE job={jobid} from={worker_name} tally={done_tally}", flush=True)
            elif buf.startswith("STATUS"):
                reply = f"STATUS {name} tally={done_tally}"
                sock.sendto(reply.encode('utf-8'), addr)
            else:
                sock.sendto(b"ERR", addr)
        except Exception:
            pass

def worker(name, port, proc_delay_ms, coord_host, coord_port):
    delay = int(proc_delay_ms) / 1000.0
    completed = set()
    seen_job = set()
    sock = bind_udp(port)
    print(f"worker {name} listening on udp/{port} with delay={proc_delay_ms}ms coord={coord_host}:{coord_port}", flush=True)

    while True:
        try:
            data, addr = sock.recvfrom(BUF)
            buf = data.decode('utf-8')

            if buf.startswith("JOB "):
                parts = buf.split()
                if len(parts) >= 2:
                    jobid = parts[1]
                    if jobid in seen_job:
                        print(f"{name} JOB job={jobid} duplicate, dropping", flush=True)
                    else:
                        seen_job.add(jobid)
                        time.sleep(delay)
                        completed.add(jobid)
                        print(f"{name} JOB job={jobid} completed={len(completed)}", flush=True)
                        send_udp(coord_host, coord_port, f"DONE {jobid} {name}")
            elif buf.startswith("STATUS"):
                reply = f"STATUS {name} done={','.join(sorted(completed))}"
                sock.sendto(reply.encode('utf-8'), addr)
            else:
                sock.sendto(b"ERR", addr)
        except Exception:
            pass

def submit(host, port, jobid):
    return 1 if send_udp(host, port, f"SUBMIT {jobid}") < 0 else 0

def status(host, port):
    reply = request_udp(host, port, "STATUS", 1000)
    if reply is None:
        return 1
    print(reply)
    return 0

def snapshot(host, port):
    return 1 if send_udp(host, port, "__START_SNAPSHOT__") < 0 else 0

def get_done(host, port):
    reply = request_udp(host, port, "STATUS", 500)
    if not reply:
        return None
    idx = reply.find("done=")
    if idx == -1:
        return None
    csv = reply[idx + len("done="):].strip()
    return set(csv.split(',')) if csv else set()

def verify(args):
    n = int(args[0])
    workers = []
    for i in range(1, len(args), 2):
        workers.append((args[i], args[i + 1]))
    universe = set(str(j) for j in range(1, n + 1))

    deadline = time.monotonic() + 15.0
    reason = "timeout"

    while time.monotonic() < deadline:
        sets = [get_done(host, port) for host, port in workers]

        if any(s is None for s in sets):
            unreachable = [f"{h}:{p}" for (h, p), s in zip(workers, sets) if s is None]
            reason = f"unreachable workers: {' '.join(unreachable)}"
            print(f"VERIFY waiting for workers: {' '.join(unreachable)}", flush=True)
        else:
            union = set()
            total = 0
            for s in sets:
                union |= s
                total += len(s)
            disjoint = total == len(union)
            complete = union == universe
            print(f"VERIFY union={len(union)}/{n} disjoint={'yes' if disjoint else 'no'}", flush=True)

            if complete and disjoint:
                print("PASS", flush=True)
                return 0
            if not disjoint:
                reason = "completed sets not disjoint"
            else:
                missing = sorted(universe - union, key=int)
                extra = sorted(union - universe, key=int)
                reason = f"missing={','.join(missing)} extra={','.join(extra)}"

        time.sleep(0.5)

    print(f"FAIL {reason}", flush=True)
    return 1

def main():
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} coordinator|worker|submit|status|snapshot|verify ...", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "coordinator":
        if len(sys.argv) < 6 or (len(sys.argv) - 4) % 2 != 0:
            print(f"usage: {sys.argv[0]} coordinator NAME PORT W1_HOST W1_PORT [W2_HOST W2_PORT ...]", file=sys.stderr)
            sys.exit(1)
        sys.exit(coordinator(sys.argv[2], sys.argv[3], sys.argv[4:]))

    elif cmd == "worker":
        if len(sys.argv) != 7:
            print(f"usage: {sys.argv[0]} worker NAME PORT PROC_DELAY_MS COORD_HOST COORD_PORT", file=sys.stderr)
            sys.exit(1)
        sys.exit(worker(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]))

    elif cmd == "submit":
        if len(sys.argv) != 5:
            print(f"usage: {sys.argv[0]} submit COORD_HOST COORD_PORT JOBID", file=sys.stderr)
            sys.exit(1)
        sys.exit(submit(sys.argv[2], sys.argv[3], sys.argv[4]))

    elif cmd == "status":
        if len(sys.argv) != 4:
            print(f"usage: {sys.argv[0]} status HOST PORT", file=sys.stderr)
            sys.exit(1)
        sys.exit(status(sys.argv[2], sys.argv[3]))

    elif cmd == "snapshot":
        if len(sys.argv) != 4:
            print(f"usage: {sys.argv[0]} snapshot PEER_HOST PEER_PORT", file=sys.stderr)
            sys.exit(1)
        sys.exit(snapshot(sys.argv[2], sys.argv[3]))

    elif cmd == "verify":
        if len(sys.argv) < 5 or (len(sys.argv) - 3) % 2 != 0:
            print(f"usage: {sys.argv[0]} verify N W1_HOST W1_PORT [W2_HOST W2_PORT ...]", file=sys.stderr)
            sys.exit(1)
        sys.exit(verify(sys.argv[2:]))

    else:
        print(f"unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
