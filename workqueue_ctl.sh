#!/bin/bash
# workqueue_ctl.sh
#
# App-specific control container for the WORK QUEUE app (src/workqueue.py),
# modeled on mesh_ctl.sh (the counter app's mesh_ctl). Drive the queue over the
# mesh from ONE node, via a long-lived control container ("workqueue-ctl")
# attached to the VXLAN overlay at a fixed mesh IP 10.24.24.200, plus its own
# sidecar ("sidecar-ctl") sharing workqueue-ctl's netns.
#
# WHY THE SIDECAR: STATUS is request/reply. The app nodes tunnel their STATUS
# replies back to 10.24.24.200 over RUDP/TPROXY; without a sidecar in the
# control container's netns those replies are never de-tunnelled and `status`
# (and the verify built on it) would hang. The control container holds the fixed
# .200 so peers have a stable address to reply to. NB: .200 is NOT a mesh member
# (config.MESH_MEMBERS = .10,.11,.12), so it is never marked/recorded in a cut.
#
# It also (optionally) brings up the standard node topology (a=coordinator,
# b/c=workers, d=client) by delegating to ./build_workqueue.sh -- the same
# launcher test/test_workqueue_snapshot.sh uses.
#
# Usage:
#   ./workqueue_ctl.sh up                       # ensure images + workqueue-ctl + sidecar-ctl
#   ./workqueue_ctl.sh deploy                   # ALSO deploy a/b/c/d via build_workqueue.sh
#   ./workqueue_ctl.sh submit  <jobid>          # SUBMIT a work item to the coordinator
#   ./workqueue_ctl.sh status  <ip> [port]      # STATUS of a node (coordinator or worker)
#   ./workqueue_ctl.sh queued                   # coordinator tally (done count it has heard)
#   ./workqueue_ctl.sh processing               # workers' completed/in-process item sets
#   ./workqueue_ctl.sh verify  <N>              # union(done(b),done(c)) == {1..N}, disjoint
#   ./workqueue_ctl.sh bootstrap [N]            # deploy(if needed)+prime+submit 1..N+verify N
#   ./workqueue_ctl.sh exec    <workqueue.py args...>   # raw passthrough
#
# Honors env: MESH_NET (default "vlan"), APP_PORT (5000), COORD_IP/W1_IP/W2_IP,
#             N_JOBS (default 10 for bootstrap).

set -u

MESH_NET="${MESH_NET:-vlan}"
APP_PORT="${APP_PORT:-5000}"
COORD_IP="${COORD_IP:-10.24.24.10}"
W1_IP="${W1_IP:-10.24.24.11}"
W2_IP="${W2_IP:-10.24.24.12}"
CTL_IP="${CTL_IP:-10.24.24.200}"
MESH_SUBNET="${MESH_SUBNET:-10.24.24.0/24}"

CTL_NAME=workqueue-ctl
CTL_SIDECAR=sidecar-ctl
# workqueue.py lives at /app inside the workqueue image (Containerfile.workqueue:
# WORKDIR /app, ENTRYPOINT ./workqueue.py). The control container overrides that
# entrypoint to sleep, then we exec workqueue.py subcommands into it.
WQ=/app/workqueue.py

ROOT=$(cd "$(dirname "$0")" && pwd)

if [ "$#" -lt 1 ]; then
    sed -n '2,40p' "$0"
    exit 1
fi

# Breakout bridge config (mirrors build_workqueue.sh) -- the sidecar's snapshot
# handler POSTs to the host-side breakout receiver here. The control container's
# sidecar never initiates a snapshot, but build_workqueue.sh-style sidecars want
# this set, so we mirror it for parity.
BREAKOUT_GW="${BREAKOUT_GW:-10.99.0.1}"
BREAKOUT_URL="${BREAKOUT_URL:-http://$BREAKOUT_GW:8989}"

# ----------------------------------------------------------------- image + ctl up
ensure_images() {
    # The control container runs workqueue.py from the `workqueue` image; the
    # sidecar provides TPROXY tunnelling so STATUS replies to .200 de-tunnel.
    if ! sudo podman image exists workqueue; then
        echo "[*] Building workqueue image..."
        sudo podman build --network=host -t workqueue -f Containerfile.workqueue "$ROOT" \
            || { echo "FATAL: workqueue image build failed" >&2; exit 2; }
    fi
    if ! sudo podman image exists sidecar; then
        echo "[*] Building sidecar image..."
        sudo podman build --network=host -t sidecar -f Containerfile.rudp "$ROOT" \
            || { echo "FATAL: sidecar image build failed" >&2; exit 2; }
    fi
}

ensure_ctl() {
    # Bring up workqueue-ctl + sidecar-ctl on the overlay if not already running.
    if ! sudo podman container exists "$CTL_NAME" || \
       [ "$(sudo podman inspect -f '{{.State.Running}}' "$CTL_NAME" 2>/dev/null)" != "true" ]; then
        echo "[*] Starting control container $CTL_NAME on $MESH_NET ($CTL_IP)"
        # Override the workqueue.py entrypoint with sleep: this container is only
        # a mesh-attached exec target (no app loop), exactly like the client (d)
        # role in build_workqueue.sh.
        sudo podman run -d --replace \
          --name "$CTL_NAME" \
          --network "${MESH_NET}:ip=${CTL_IP}" \
          --entrypoint "" \
          workqueue sleep infinity \
            || { echo "FATAL: could not start $CTL_NAME" >&2; exit 2; }

        echo "[*] Attaching $CTL_SIDECAR (shares $CTL_NAME netns)"
        sudo podman run -d --replace \
          --name "$CTL_SIDECAR" \
          --network "container:$CTL_NAME" \
          --cap-add NET_ADMIN \
          --sysctl net.ipv4.ip_nonlocal_bind=1 \
          -e MESH_SUBNET="$MESH_SUBNET" \
          -e BREAKOUT_URL="$BREAKOUT_URL" \
          sidecar \
            || { echo "FATAL: could not start $CTL_SIDECAR" >&2; exit 2; }

        sleep 1  # let the sidecar install its TPROXY rules
    fi
}

# Run a workqueue.py subcommand from the control container, on the mesh.
cexec() { sudo podman exec "$CTL_NAME" python3 "$WQ" "$@"; }

deploy_nodes() {
    # Bring up the standard topology via the SAME launcher the snapshot harness
    # uses: a=coordinator, b/c=workers, d=client. Idempotent (--replace inside).
    echo "[*] Deploying nodes a=coordinator b/c=workers d=client via build_workqueue.sh"
    ( cd "$ROOT" && ./build_workqueue.sh a coordinator ) || { echo "FATAL: deploy a" >&2; exit 2; }
    ( cd "$ROOT" && ./build_workqueue.sh b worker )      || { echo "FATAL: deploy b" >&2; exit 2; }
    ( cd "$ROOT" && ./build_workqueue.sh c worker )      || { echo "FATAL: deploy c" >&2; exit 2; }
    ( cd "$ROOT" && ./build_workqueue.sh d client )      || { echo "FATAL: deploy d" >&2; exit 2; }
    echo "[*] Letting sidecars finish TPROXY setup..."
    sleep 3
}

prime() {
    # Warm the control container's channel to coordinator + both workers so the
    # first SUBMIT/STATUS does not pay the probe handshake. Retries until tunneled.
    for ip in "$COORD_IP" "$W1_IP" "$W2_IP"; do
        local primed=false deadline=$(( $(date +%s) + 30 ))
        while [ "$(date +%s)" -lt "$deadline" ]; do
            if out=$(cexec status "$ip" "$APP_PORT" 2>/dev/null); then
                echo "[*] primed $ip: $out"; primed=true; break
            fi
            sleep 1
        done
        [ "$primed" = true ] || { echo "FATAL: could not prime ctl<->$ip" >&2; exit 2; }
    done
}

# ----------------------------------------------------------------- verbs
VERB="$1"; shift || true

case "$VERB" in
    up)
        ensure_images; ensure_ctl
        echo "[*] $CTL_NAME ($CTL_IP) + $CTL_SIDECAR are up on $MESH_NET."
        ;;

    deploy)
        ensure_images; ensure_ctl; deploy_nodes
        echo "[*] Control container + a/b/c/d nodes are up."
        ;;

    submit)
        [ "$#" -ge 1 ] || { echo "usage: $0 submit <jobid>" >&2; exit 1; }
        ensure_images; ensure_ctl
        cexec submit "$COORD_IP" "$APP_PORT" "$1"
        ;;

    status)
        [ "$#" -ge 1 ] || { echo "usage: $0 status <ip> [port]" >&2; exit 1; }
        ensure_images; ensure_ctl
        cexec status "$1" "${2:-$APP_PORT}"
        ;;

    queued)
        # Coordinator-side view: STATUS coord -> "STATUS <name> tally=<done count>".
        # (The coordinator forwards-and-forgets per item, so it has no queue of
        # outstanding items -- only a tally of DONEs it has heard back.)
        ensure_images; ensure_ctl
        cexec status "$COORD_IP" "$APP_PORT"
        ;;

    processing)
        # Worker-side view: each worker's STATUS -> "STATUS <name> done=<csv>".
        # `done=` is that worker's assigned+completed item set (seen_job -> sleep
        # -> completed); this is the in-NODE item state half of the cut.
        ensure_images; ensure_ctl
        echo "worker b:"; cexec status "$W1_IP" "$APP_PORT"
        echo "worker c:"; cexec status "$W2_IP" "$APP_PORT"
        ;;

    verify)
        [ "$#" -ge 1 ] || { echo "usage: $0 verify <N>" >&2; exit 1; }
        ensure_images; ensure_ctl
        cexec verify "$1" "$W1_IP" "$APP_PORT" "$W2_IP" "$APP_PORT"
        ;;

    bootstrap)
        # Convenience: ensure ctl, deploy nodes if any are missing, prime, submit
        # 1..N, verify N. Mirrors mesh_ctl.sh bootstrap (reset/warm/verify).
        N="${1:-${N_JOBS:-10}}"
        ensure_images; ensure_ctl
        need_deploy=false
        for c in workqueue-a workqueue-b workqueue-c workqueue-d; do
            sudo podman container exists "$c" || need_deploy=true
        done
        [ "$need_deploy" = true ] && deploy_nodes
        prime
        echo "[*] bootstrap: submit 1..$N, verify N=$N"
        for j in $(seq 1 "$N"); do
            cexec submit "$COORD_IP" "$APP_PORT" "$j" || { echo "FATAL: submit $j" >&2; exit 2; }
        done
        cexec verify "$N" "$W1_IP" "$APP_PORT" "$W2_IP" "$APP_PORT"
        exit $?
        ;;

    exec)
        ensure_images; ensure_ctl
        cexec "$@"
        ;;

    *)
        echo "unknown verb: $VERB" >&2
        sed -n '2,40p' "$0"
        exit 1
        ;;
esac
