#!/bin/bash
# tokenring_ctl.sh
#
# Drive the token-ring app over the mesh from ONE node, via a long-lived control
# container ("tokenring-ctl") attached to the VXLAN overlay at 10.24.24.200, plus
# its own sidecar ("sidecar-ctl") sharing that netns. This is the operator's hand
# on the ring: inject a token, watch it pass, and query who holds it.
#
# Modeled on mesh_ctl.sh (the counter app's control container). The differences:
#   - the client is the token-ring app (src/tokenring.py), which ships inside the
#     `tokenring` image at /app/tokenring.py (Containerfile.tokenring: WORKDIR
#     /app, ENTRYPOINT ./tokenring.py). So the control container runs the
#     `tokenring` image with --entrypoint sleep, and verbs exec ./tokenring.py.
#   - .200 must NOT be a ring member: MESH_MEMBERS is 10.24.24.10/11/12, and the
#     snapshot recording set is derived from that, so the control container is
#     never marked or recorded. Its sidecar exists ONLY so STATUS replies that the
#     ring nodes tunnel back to .200 over RUDP/TPROXY get de-tunnelled (otherwise
#     `status`/`who` would hang), exactly as in mesh_ctl.sh.
#
# Usage:
#   ./tokenring_ctl.sh up                 # just bring up tokenring-ctl + sidecar-ctl
#   ./tokenring_ctl.sh nodes              # bring up the 3 ring nodes a/b/c (calls build_tokenring.sh)
#   ./tokenring_ctl.sh bootstrap          # up + nodes + verify one token circulates
#   ./tokenring_ctl.sh who                # which node currently holds the token (have=1)
#   ./tokenring_ctl.sh status <ip> <port> # raw STATUS of one node
#   ./tokenring_ctl.sh inject <suffix>    # (re)deploy node <suffix> as the SOLE token holder
#   ./tokenring_ctl.sh verify [rounds]    # app's own verify across the ring
#   ./tokenring_ctl.sh exec <tokenring.py args...>   # raw passthrough to the app client
#
# Env knobs:
#   MESH_NET     overlay network name (default "vlan"); operator pre-creates it.
#   A_IP/B_IP/C_IP   ring node IPs (default 10.24.24.10/.11/.12).
#   PORT         app udp port (default 5000).
#   HOLD_MS / LOSS_TIMEOUT_MS   passed through to build_tokenring.sh on `nodes`.

set -u

MESH_NET="${MESH_NET:-vlan}"
MESH_SUBNET="10.24.24.0/24"
CTL_IP="10.24.24.200"
A_IP="${A_IP:-10.24.24.10}"; B_IP="${B_IP:-10.24.24.11}"; C_IP="${C_IP:-10.24.24.12}"
PORT="${PORT:-5000}"
BREAKOUT_URL="${BREAKOUT_URL:-http://10.99.0.1:8989}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

usage() {
    sed -n '2,40p' "$ROOT/tokenring_ctl.sh"
    exit 1
}

[ "$#" -ge 1 ] || usage

# 1. Ensure the images exist. The control container runs the app client from the
#    `tokenring` image (WORKDIR /app, ENTRYPOINT ./tokenring.py); the sidecar
#    provides the TPROXY/RUDP de-tunnelling for replies back to .200.
ensure_images() {
    if ! sudo podman image exists tokenring; then
        echo "[*] Building tokenring image..."
        sudo podman build --network=host -t tokenring -f "$ROOT/Containerfile.tokenring" "$ROOT"
    fi
    if ! sudo podman image exists sidecar; then
        echo "[*] Building sidecar image..."
        sudo podman build --network=host -t sidecar -f "$ROOT/Containerfile.rudp" "$ROOT"
    fi
}

# 2. Bring up the control container + its sidecar on the overlay. The control
#    container holds the fixed mesh IP 10.24.24.200 so ring nodes have a stable
#    address to reply to. The sidecar shares its netns because the ring nodes
#    tunnel STATUS replies back to .200 over RUDP/TPROXY; without the sidecar
#    those replies would never be de-tunnelled and `who`/`status` would hang.
#    We override the tokenring image's ENTRYPOINT with `sleep infinity` so the
#    control container is a long-lived exec target, not a ring node.
ensure_ctl() {
    if ! sudo podman container exists tokenring-ctl \
       || [ "$(sudo podman inspect -f '{{.State.Running}}' tokenring-ctl 2>/dev/null)" != "true" ]; then
        echo "[*] Starting control container tokenring-ctl on $MESH_NET ($CTL_IP)"
        sudo podman run -d --replace \
          --name tokenring-ctl \
          --network "${MESH_NET}:ip=${CTL_IP}" \
          --entrypoint sleep \
          tokenring infinity

        echo "[*] Attaching sidecar-ctl (shares tokenring-ctl netns)"
        # No CHECKPOINT_TARGET / BREAKOUT_URL needed: this sidecar never
        # checkpoints anything and is excluded from the recording set (.200 is
        # not in MESH_MEMBERS). It just de-tunnels replies addressed to .200.
        sudo podman run -d --replace \
          --name sidecar-ctl \
          --network container:tokenring-ctl \
          --cap-add NET_ADMIN \
          --sysctl net.ipv4.ip_nonlocal_bind=1 \
          -e MESH_SUBNET="$MESH_SUBNET" \
          sidecar

        sleep 1  # give the sidecar a moment to install its TPROXY rules
    fi
}

# Poll until every named container is Running. build_tokenring.sh ends with a
# blocking `podman logs -f <sidecar>` and so NEVER returns -- we must synchronize
# on container state, not by `wait`ing on the (immortal) deploy job.
wait_running() {
    local name up i
    for name in "$@"; do
        up=false
        for i in $(seq 1 60); do
            if [ "$(sudo podman inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" = "true" ]; then
                up=true; break
            fi
            sleep 1
        done
        [ "$up" = true ] || { echo "[!] $name did not come up within 60s" >&2; return 1; }
    done
}

# Poll node logs until the token is actually circulating: some node has logged a
# RECEIVE (the token arrived over the proxy) or a REGENERATE (loss recovery minted
# one). Returns as soon as a token exists, so the caller never hands a tokenless
# ring to `verify`. Covers up to a full LOSS_TIMEOUT_MS regeneration.
wait_token() {
    local i x
    for i in $(seq 1 "${1:-80}"); do
        for x in a b c; do
            if sudo podman logs "tokenring-$x" 2>&1 | grep -qE "RECEIVE|REGENERATE"; then
                return 0
            fi
        done
        sleep 1
    done
    return 1
}

# 3. Bring up the three ring nodes a/b/c via build_tokenring.sh. a/b boot WITHOUT
#    the token, c boots WITH it (HAS_TOKEN=1) and must be deployed LAST so its
#    successor (a) is already listening when the boot token is forwarded. This
#    yields exactly one token in the ring. Each node carries its own sidecar.
#
#    Two proxy-mode realities are handled here:
#    - The app forwards its boot token HOLD_MS after start, but the sidecar (which
#      installs the TPROXY rules) starts AFTER the app. With the 500ms default the
#      boot token egresses before the sidecar is ready and is lost. We default
#      HOLD_MS high enough (5s) that c's sidecar is up before the boot forward.
#    - LOSS_TIMEOUT_MS (default 60s, matching the demo) lets the ring self-heal a
#      lost token by regeneration; it must stay well above NETEM_MS so the
#      deliberate in-flight hold in the verify test never triggers a false regen.
ensure_nodes() {
    local HOLD_MS_V="${HOLD_MS:-5000}" LOSS_V="${LOSS_TIMEOUT_MS:-60000}"
    echo "[*] Deploying ring nodes a -> b -> c -> a (c holds the boot token; HOLD_MS=$HOLD_MS_V LOSS_TIMEOUT_MS=$LOSS_V)"
    # build_tokenring.sh tails the sidecar logs (podman logs -f) and never exits,
    # so background each deploy and poll for the containers -- a bare `wait` here
    # would hang forever on that log tail.
    ( cd "$ROOT" && HOLD_MS="$HOLD_MS_V" LOSS_TIMEOUT_MS="$LOSS_V" ./build_tokenring.sh a A 0 y ) >/dev/null 2>&1 &
    ( cd "$ROOT" && HOLD_MS="$HOLD_MS_V" LOSS_TIMEOUT_MS="$LOSS_V" ./build_tokenring.sh b B 0 y ) >/dev/null 2>&1 &
    wait_running tokenring-a sidecar-a tokenring-b sidecar-b || return 1
    # c LAST and with the token, so its successor (a) is already listening.
    ( cd "$ROOT" && HOLD_MS="$HOLD_MS_V" LOSS_TIMEOUT_MS="$LOSS_V" ./build_tokenring.sh c C 1 y ) >/dev/null 2>&1 &
    wait_running tokenring-c sidecar-c || return 1
    echo "[*] Ring nodes deployed; waiting for the token to start circulating..."
    wait_token || { echo "[!] no token observed circulating (boot token lost AND no regen?)" >&2; return 1; }
    echo "[*] Token is circulating."
}

# Run the app client inside the control container. The token-ring client verbs
# are status / snapshot / verify (src/tokenring.py); `node` is a server verb and
# is NOT run here.
cexec() { sudo podman exec tokenring-ctl ./tokenring.py "$@"; }

# who: probe every ring node's STATUS and report which one has have=1.
who() {
    local found=""
    for pair in "a:$A_IP" "b:$B_IP" "c:$C_IP"; do
        local name="${pair%%:*}" ip="${pair##*:}"
        local reply
        reply="$(cexec status "$ip" "$PORT" 2>/dev/null)"
        local have="?"
        case "$reply" in *have=1*) have=1 ;; *have=0*) have=0 ;; esac
        echo "  $name ($ip): ${reply:-<no reply>}"
        [ "$have" = 1 ] && found="$found $name"
    done
    if [ -n "$found" ]; then
        echo "[*] token held by:$found"
    else
        echo "[*] no node reports have=1 (token may be IN FLIGHT on a channel right now)"
    fi
}

CMD="$1"; shift || true
case "$CMD" in
    up)
        ensure_images; ensure_ctl
        echo "[*] control container ready at $CTL_IP (mesh net $MESH_NET)"
        ;;

    nodes)
        ensure_images; ensure_nodes
        ;;

    bootstrap)
        ensure_images; ensure_ctl; ensure_nodes
        echo "[*] bootstrap: verifying exactly one token circulates"
        cexec verify "${1:-15}" "$A_IP" "$PORT" "$B_IP" "$PORT" "$C_IP" "$PORT"
        ;;

    who)
        ensure_images; ensure_ctl
        who
        ;;

    status)
        [ "$#" -eq 2 ] || { echo "usage: $0 status <ip> <port>" >&2; exit 1; }
        ensure_images; ensure_ctl
        cexec status "$1" "$2"
        ;;

    inject)
        # (Re)deploy node <suffix> as the SOLE token holder. Use this to seed a
        # fresh ring with exactly one token, or to re-inject after loss. Caller is
        # responsible for ensuring no OTHER node also holds one.
        [ "$#" -eq 1 ] || { echo "usage: $0 inject <suffix:a|b|c>" >&2; exit 1; }
        ensure_images
        local_node="$1"
        echo "[*] (re)deploying node $local_node as the sole token holder"
        ( cd "$ROOT" && ./build_tokenring.sh "$local_node" "$local_node" 1 y ) &
        sleep 4
        ;;

    verify)
        ensure_images; ensure_ctl
        cexec verify "${1:-15}" "$A_IP" "$PORT" "$B_IP" "$PORT" "$C_IP" "$PORT"
        ;;

    exec)
        ensure_images; ensure_ctl
        cexec "$@"
        ;;

    *)
        usage
        ;;
esac
