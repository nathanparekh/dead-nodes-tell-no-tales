#!/bin/bash
# Reproducible static analysis of the whole repo.
# Run from the repo root:  ./claude_screen/harness/run.sh
# Builds two tool images and runs them with the repo mounted read-only.
# All tool output lands in claude_screen/analysis_output/.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS="$REPO/claude_screen/harness"
OUT="$REPO/claude_screen/analysis_output"
mkdir -p "$OUT"

echo "[*] Repo: $REPO"
echo "[*] Building tool images..."
podman build -t dnt-tools   -f "$HARNESS/Containerfile.tools"   "$HARNESS"
podman build -t dnt-pytools -f "$HARNESS/Containerfile.pytools" "$HARNESS"

echo "[*] Running C / shell analysis..."
podman run --rm \
  -v "$REPO":/work:ro \
  -v "$OUT":/out:rw \
  -v "$HARNESS/analyze_c.sh":/analyze_c.sh:ro \
  dnt-tools sh /analyze_c.sh

echo "[*] Running Python analysis..."
podman run --rm \
  -v "$REPO":/work:ro \
  -v "$OUT":/out:rw \
  -v "$HARNESS/analyze_py.sh":/analyze_py.sh:ro \
  dnt-pytools sh /analyze_py.sh

echo "[*] Analysis complete. See $OUT"
