#!/usr/bin/env python3
import sys
import socket
import time

BUF = 65536

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

def node(name, port, next_host, next_port, has_token, hold_ms, loss_timeout_ms="0"):
    hold = int(hold_ms) / 1000.0
    loss_timeout = int(loss_timeout_ms) / 1000.0
    have_token = 1 if has_token == "1" else 0
    epoch = 0
    witnessed = set()
    last_applied = 0
    token_seq = 1
    last_seen = time.time()
    forward_at = last_seen + hold

    sock = bind_udp(port)
    print(f"node {name} listening on udp/{port} next={next_host}:{next_port} have_token={have_token} hold_ms={hold_ms} loss_timeout_ms={loss_timeout_ms}", flush=True)

    while True:
        now = time.time()

        if have_token and now >= forward_at:
            send_udp(next_host, next_port, f"TOKEN {token_seq} {epoch}")
            print(f"{name} FORWARD seq={token_seq} epoch={epoch} to={next_host}:{next_port}", flush=True)
            have_token = 0
            last_seen = now

        if loss_timeout > 0 and not have_token and now - last_seen > loss_timeout:
            epoch = (max(witnessed) if witnessed else 0) + 1
            witnessed.add(epoch)
            token_seq = last_applied + 1000
            have_token = 1
            forward_at = now + hold
            print(f"{name} REGENERATE seq={token_seq} epoch={epoch}", flush=True)

        timeout = 0.05
        if have_token:
            timeout = min(timeout, forward_at - now)
        elif loss_timeout > 0:
            timeout = min(timeout, last_seen + loss_timeout - now)
        sock.settimeout(max(timeout, 0.005))

        try:
            data, addr = sock.recvfrom(BUF)
            buf = data.decode('utf-8')

            if buf.startswith("STATUS"):
                csv = ",".join(str(e) for e in sorted(witnessed))
                reply = f"STATUS {name} have={have_token} epoch={epoch} cs={csv}"
                sock.sendto(reply.encode('utf-8'), addr)
            elif buf.startswith("TOKEN "):
                parts = buf.split()
                if len(parts) >= 3:
                    seq = int(parts[1])
                    rx_epoch = int(parts[2])
                    if seq <= last_applied:
                        print(f"{name} DROP seq={seq} last_applied={last_applied}", flush=True)
                    else:
                        last_applied = seq
                        token_seq = seq + 1
                        epoch = rx_epoch + 1
                        witnessed.add(epoch)
                        have_token = 1
                        forward_at = time.time() + hold
                        print(f"{name} RECEIVE seq={seq} epoch={epoch}", flush=True)
        except Exception:
            pass

def status(host, port):
    reply = request_udp(host, port, "STATUS", 1000)
    if reply is None:
        return 1
    print(reply)
    return 0

def snapshot(next_host, next_port):
    send_udp(next_host, next_port, "__START_SNAPSHOT__")
    return 0

def get_status(host, port):
    reply = request_udp(host, port, "STATUS", 1000)
    if reply is None:
        return None
    have = None
    cs = set()
    for part in reply.split():
        if part.startswith("have="):
            have = int(part[len("have="):])
        elif part.startswith("cs="):
            csv = part[len("cs="):]
            if csv:
                cs = set(int(e) for e in csv.split(","))
    if have is None:
        return None
    return have, cs

def verify(args):
    rounds = int(args[0])
    nodes = [(args[1], args[2]), (args[3], args[4]), (args[5], args[6])]
    saw_one_holder = 0

    for _ in range(rounds):
        results = [get_status(host, port) for host, port in nodes]

        if any(r is None for r in results):
            down = " ".join(f"{host}:{port}" for (host, port), r in zip(nodes, results) if r is None)
            print(f"VERIFY waiting for nodes: {down}", flush=True)
            time.sleep(0.5)
            continue

        holders = sum(have for have, cs in results)
        epochs = []
        for have, cs in results:
            epochs.extend(cs)
        union = set(epochs)

        dups = sorted(e for e in union if epochs.count(e) > 1)
        if dups:
            print(f"FAIL duplicate epoch(s): {','.join(str(e) for e in dups)}", flush=True)
            return 1

        missing = sorted(set(range(1, max(union) + 1)) - union) if union else []
        if missing:
            print(f"FAIL missing epoch(s): {','.join(str(e) for e in missing)}", flush=True)
            return 1

        if holders == 1:
            saw_one_holder = 1

        print(f"VERIFY holders={holders} epochs={len(union)} max={max(union) if union else 0}", flush=True)
        time.sleep(0.5)

    if saw_one_holder:
        print("PASS", flush=True)
        return 0
    print("FAIL never saw exactly one token holder", flush=True)
    return 1

def main():
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} node|status|snapshot|verify ...", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "node":
        if len(sys.argv) not in (8, 9):
            print(f"usage: {sys.argv[0]} node NAME PORT NEXT_HOST NEXT_PORT HAS_TOKEN HOLD_MS [LOSS_TIMEOUT_MS]", file=sys.stderr)
            sys.exit(1)
        sys.exit(node(*sys.argv[2:]))

    elif cmd == "status":
        if len(sys.argv) != 4:
            print(f"usage: {sys.argv[0]} status HOST PORT", file=sys.stderr)
            sys.exit(1)
        sys.exit(status(sys.argv[2], sys.argv[3]))

    elif cmd == "snapshot":
        if len(sys.argv) != 4:
            print(f"usage: {sys.argv[0]} snapshot NEXT_HOST NEXT_PORT", file=sys.stderr)
            sys.exit(1)
        sys.exit(snapshot(sys.argv[2], sys.argv[3]))

    elif cmd == "verify":
        if len(sys.argv) != 9:
            print(f"usage: {sys.argv[0]} verify N A_HOST A_PORT B_HOST B_PORT C_HOST C_PORT", file=sys.stderr)
            sys.exit(1)
        sys.exit(verify(sys.argv[2:]))

    else:
        print(f"unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
