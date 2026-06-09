#!/bin/sh
# Runs inside dnt-pytools. Repo mounted read-only at /work, output dir at /out.
set -u
OUT=/out
mkdir -p "$OUT"

echo "=== versions ===" | tee "$OUT/00_py_versions.txt"
{ python --version; pyflakes --version; pylint --version; mypy --version; vulture --version; } >> "$OUT/00_py_versions.txt" 2>&1

# proxy modules import each other (from config import *), so analyze from that dir
PROXY=/work/proxy
SRC=/work/src
PYFILES="$PROXY/mesh_proxy.py $PROXY/snapshot_handler.py $PROXY/config.py $PROXY/chat.py $PROXY/udp_script.py $SRC/redis_client.py"

echo "### py_compile (syntax)"
: > "$OUT/30_py_compile.txt"
for f in $PYFILES; do
  echo "===== $f =====" >> "$OUT/30_py_compile.txt"
  python -m py_compile "$f" >> "$OUT/30_py_compile.txt" 2>&1 && echo "OK" >> "$OUT/30_py_compile.txt"
done

echo "### pyflakes (undefined names, unused, etc.)"
pyflakes $PYFILES > "$OUT/31_pyflakes.txt" 2>&1

echo "### pylint ERRORS ONLY (-E): catches bad arg counts, unbalanced unpacking, undefined"
# run inside proxy dir so 'from config import *' resolves
cd "$PROXY" && pylint -E mesh_proxy.py snapshot_handler.py config.py chat.py udp_script.py > "$OUT/32_pylint_errors_proxy.txt" 2>&1
cd "$SRC"   && pylint -E redis_client.py > "$OUT/33_pylint_errors_src.txt" 2>&1

echo "### pylint FULL (warnings too) for proxy core"
cd "$PROXY" && pylint --disable=C,R mesh_proxy.py snapshot_handler.py > "$OUT/34_pylint_full_proxy.txt" 2>&1

echo "### mypy (type checks; may surface arg/tuple mismatches)"
cd "$PROXY" && mypy --ignore-missing-imports --no-error-summary mesh_proxy.py snapshot_handler.py config.py > "$OUT/35_mypy_proxy.txt" 2>&1
cd "$SRC"   && mypy --ignore-missing-imports --no-error-summary redis_client.py > "$OUT/36_mypy_src.txt" 2>&1

echo "### vulture (dead code)"
vulture $PYFILES > "$OUT/37_vulture.txt" 2>&1

echo "### DONE (python). Outputs in $OUT"
ls -la "$OUT"
