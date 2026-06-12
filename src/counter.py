#!/usr/bin/env python3
import sys
import socket
import time

BUF = 512
PORT = 5000

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
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(('', PORT)) 
    try:
        sock.sendto(msg.encode('utf-8'), (host, int(port)))
        sock.settimeout(timeout_ms / 1000.0)
        data, addr = sock.recvfrom(BUF)
        sock.close()
        return data.decode('utf-8')
    except Exception:
        sock.close()
        return None

def node(name, port, init_counter):
    counter = int(init_counter)
    sock = bind_udp(port)
    print(f"node {name} listening on udp/{port} with counter={counter}", flush=True)

    while True:
        try:
            data, addr = sock.recvfrom(BUF)
            buf = data.decode('utf-8')
            
            if buf.startswith("STATE"):
                reply = f"STATE {name} counter={counter}"
                sock.sendto(reply.encode('utf-8'), addr)
            elif buf.startswith("CREDIT "):
                parts = buf.split()
                if len(parts) >= 4:
                    txid = parts[1]
                    from_node = parts[2]
                    amount = int(parts[3])
                    counter += amount
                    print(f"{name} CREDIT tx={txid} from={from_node} amount={amount} counter={counter}", flush=True)
                    reply = f"OK CREDIT {txid}"
                    sock.sendto(reply.encode('utf-8'), addr)
            elif buf.startswith("TRANSFER "):
                parts = buf.split()
                if len(parts) >= 5:
                    txid = parts[1]
                    host = parts[2]
                    peer_port = parts[3]
                    amount = int(parts[4])
                    
                    counter -= amount
                    print(f"{name} DEBIT tx={txid} to={host}:{peer_port} amount={amount} counter={counter}", flush=True)
                    
                    credit_msg = f"CREDIT {txid} {name} {amount}"
                    send_udp(host, peer_port, credit_msg)
                    
                    reply = f"OK TRANSFER {txid}"
                    sock.sendto(reply.encode('utf-8'), addr)
            elif buf.startswith("RESET "):
                parts = buf.split()
                if len(parts) >= 2:
                    amount = int(parts[1])
                    counter = amount
                    print(f"{name} RESET amount={amount} counter={counter}", flush=True)
                    reply = "OK RESET"
                    sock.sendto(reply.encode('utf-8'), addr)
            else:
                sock.sendto(b"ERR", addr)
        except Exception:
            pass

def state(host, port):
    reply = request_udp(host, port, "STATE", 1000)
    if reply is None:
        return 1
    print(reply)
    return 0

def transfer(from_host, from_port, to_host, to_port, amount):
    msg = f"TRANSFER tx123 {to_host} {to_port} {amount}"
    reply = request_udp(from_host, from_port, msg, 1000)
    if reply is None:
        return 1
    print(reply)
    return 0 if reply.startswith("OK") else 1

def reset_counter(host, port, amount):
    msg = f"RESET {amount}"
    reply = request_udp(host, port, msg, 1000)
    if reply is None:
        return 1
    print(reply)
    return 0 if reply.startswith("OK") else 1

def get_counter(host, port):
    reply = request_udp(host, port, "STATE", 500)
    if not reply:
        return None
    idx = reply.find("counter=")
    if idx == -1:
        return None
    try:
        return int(reply[idx + len("counter="):].split()[0])
    except:
        return None

def sum_counters(args):
    a_host, a_port = args[0], args[1]
    b_host, b_port = args[2], args[3]
    c_host, c_port = args[4], args[5]
    expected = int(args[6])
    timeout_ms = int(args[7])
    stable_needed = int(args[8])
    
    elapsed = 0
    stable = 0
    
    while elapsed <= timeout_ms:
        a = get_counter(a_host, a_port)
        b = get_counter(b_host, b_port)
        c = get_counter(c_host, c_port)
        
        if a is not None and b is not None and c is not None:
            total = a + b + c
            status = "PASS" if total == expected else "FAIL"
            print(f"SUM a={a} b={b} c={c} total={total} expected={expected} {status}", flush=True)
            
            if total == expected:
                stable += 1
            else:
                stable = 0
                
            if stable >= stable_needed:
                return 0
        else:
            print(f"SUM waiting for nodes: {'a' if a is None else ''} {'b' if b is None else ''} {'c' if c is None else ''}", flush=True)
            stable = 0
            
        time.sleep(0.5)
        elapsed += 100
        
    return 1

def main():
    if len(sys.argv) < 2:
        die(f"usage: {sys.argv[0]} node|state|transfer|reset|sum ...")

    cmd = sys.argv[1]

    if cmd == "node":
        if len(sys.argv) != 5:
            die(f"usage: {sys.argv[0]} node NAME PORT INITIAL")
        sys.exit(node(sys.argv[2], sys.argv[3], sys.argv[4]))

    elif cmd == "state":
        if len(sys.argv) != 4:
            die(f"usage: {sys.argv[0]} state HOST PORT")
        sys.exit(state(sys.argv[2], sys.argv[3]))

    elif cmd == "transfer":
        if len(sys.argv) != 7:
            die(f"usage: {sys.argv[0]} transfer FROM_HOST FROM_PORT TO_HOST TO_PORT AMOUNT")
        sys.exit(transfer(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]))

    elif cmd == "reset":
        if len(sys.argv) != 5:
            die(f"usage: {sys.argv[0]} reset HOST PORT AMOUNT")
        sys.exit(reset_counter(sys.argv[2], sys.argv[3], sys.argv[4]))

    elif cmd == "sum":
        if len(sys.argv) != 11:
            die(f"usage: {sys.argv[0]} sum A_HOST A_PORT B_HOST B_PORT C_HOST C_PORT EXPECTED TIMEOUT_MS STABLE_POLLS")
        sys.exit(sum_counters(sys.argv[2:]))

    else:
        die(f"unknown command: {cmd}")

if __name__ == "__main__":
    main()

