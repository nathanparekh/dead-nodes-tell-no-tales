#!/bin/bash
# Reproducible runtime proofs of selected bugs.
# Run from repo root:  ./claude_screen/repros/run_repros.sh
# - Python repro: snapshot_handler / mesh_proxy crashers (no deps, no root).
# - C repro: counter.c value-conservation / auth defects (needs gcc -> dnt-tools).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$REPO/claude_screen/repros/output"
mkdir -p "$OUT"

echo "[*] Ensure dnt-tools image exists (for gcc)..."
if ! podman image exists dnt-tools; then
  podman build -t dnt-tools -f "$REPO/claude_screen/harness/Containerfile.tools" "$REPO/claude_screen/harness"
fi

echo "[*] Python repro (proxy/snapshot crashers)..."
podman run --rm \
  -v "$REPO":/work:ro \
  -e PYTHONPATH=/work/proxy \
  docker.io/library/python:3.11-slim \
  python3 /work/claude_screen/repros/repro_snapshot_bugs.py | tee "$OUT/repro_snapshot_bugs.txt"

echo
echo "[*] C repro (counter.c value conservation / auth)..."
podman run --rm \
  -v "$REPO":/work:ro \
  dnt-tools sh /work/claude_screen/repros/repro_counter.sh | tee "$OUT/repro_counter.txt"

echo
echo "[*] Python repro (counter.py — post-merge app; same defects)..."
podman run --rm \
  -v "$REPO":/work:ro \
  docker.io/library/python:3.11-slim \
  sh /work/claude_screen/repros/repro_counter_py.sh | tee "$OUT/repro_counter_py.txt"

echo
echo "[*] Repros complete. Output in $OUT"
