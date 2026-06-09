#!/bin/sh
# Runs inside dnt-tools. Repo mounted read-only at /work, output dir at /out.
# Never fail-fast: capture every tool's output independently.
set -u
OUT=/out
mkdir -p "$OUT"

echo "=== uname / versions ==="            | tee "$OUT/00_versions.txt"
{ uname -a; gcc --version | head -1; clang --version | head -1; cppcheck --version; shellcheck --version | head -2; } >> "$OUT/00_versions.txt" 2>&1

echo "### Compiling src/counter.c with the project's exact flags (-Wall -Wextra -Werror -O2)"
gcc -Wall -Wextra -Werror -O2 -o /tmp/counter /work/src/counter.c > "$OUT/10_counter_build.txt" 2>&1
echo "counter.c build exit=$?" >> "$OUT/10_counter_build.txt"

echo "### Compiling src/tcp-howto.c (-Wall -Wextra)"
gcc -Wall -Wextra -o /tmp/tcp-howto /work/src/tcp-howto.c > "$OUT/11_tcphowto_build.txt" 2>&1
echo "tcp-howto.c build exit=$?" >> "$OUT/11_tcphowto_build.txt"

echo "### gcc -fanalyzer (deep) on both C files"
gcc -fanalyzer -Wall -Wextra -O2 -c /work/src/counter.c -o /tmp/c1.o   > "$OUT/12_gcc_analyzer_counter.txt" 2>&1
gcc -fanalyzer -Wall -Wextra -c /work/src/tcp-howto.c -o /tmp/c2.o      > "$OUT/13_gcc_analyzer_tcphowto.txt" 2>&1

echo "### cppcheck (all checks, inconclusive enabled)"
cppcheck --enable=all --inconclusive --std=c11 --platform=unix64 \
  /work/src/counter.c /work/src/tcp-howto.c > "$OUT/14_cppcheck.txt" 2>&1

echo "### clang static analyzer"
clang --analyze -Xclang -analyzer-output=text -Wall -Wextra /work/src/counter.c   > "$OUT/15_clang_analyze_counter.txt" 2>&1
clang --analyze -Xclang -analyzer-output=text -Wall -Wextra /work/src/tcp-howto.c > "$OUT/16_clang_analyze_tcphowto.txt" 2>&1

echo "### shellcheck on every shell script"
# -x follows sources; -S style = report everything
find /work -name '*.sh' -not -path '*/claude_screen/*' | sort > "$OUT/_shell_list.txt"
: > "$OUT/20_shellcheck.txt"
while IFS= read -r f; do
  echo "===== $f =====" >> "$OUT/20_shellcheck.txt"
  shellcheck -S style "$f" >> "$OUT/20_shellcheck.txt" 2>&1
  echo "(shellcheck exit=$?)" >> "$OUT/20_shellcheck.txt"
done < "$OUT/_shell_list.txt"
# entrypoint.sh is /bin/sh
echo "===== /work/proxy/entrypoint.sh =====" >> "$OUT/20_shellcheck.txt"
shellcheck -S style /work/proxy/entrypoint.sh >> "$OUT/20_shellcheck.txt" 2>&1

echo "### DONE (C/shell). Outputs in $OUT"
ls -la "$OUT"
