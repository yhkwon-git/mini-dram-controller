#!/usr/bin/env bash
# Random regression: every traffic pattern x SEEDS seeds, N requests per run.
# `make regress` calls this after building BIN (`make rand-build`).
# Each run appends one line to $OUT/regress.csv. A passing run's log is
# deleted; a failing run keeps its log in $OUT.
set -u

BIN=${BIN:-obj_dir_rand/sim_rand}
OUT=${OUT:-build/regress}
SEEDS=${SEEDS:-20}
N=${N:-2000}
PATTERNS=${PATTERNS:-"seq rowhit mixed rand hotbank stride"}

mkdir -p "$OUT"
rm -f "$OUT"/regress.csv "$OUT"/*.log

runs=0
fails=0
for p in $PATTERNS; do
  for s in $(seq 1 "$SEEDS"); do
    runs=$((runs + 1))
    log="$OUT/${p}_seed${s}.log"
    if "$BIN" +PATTERN="$p" +SEED="$s" +N="$N" +CSV="$OUT/regress.csv" > "$log" 2>&1; then
      rm -f "$log"
    else
      fails=$((fails + 1))
      echo "FAIL pattern=$p seed=$s -> $log"
    fi
  done
done

echo "regress: $runs runs ($SEEDS seeds x $N requests per pattern): $((runs - fails)) passed, $fails failed"
[ "$fails" -eq 0 ]
