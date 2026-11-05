#!/usr/bin/env bash
# Random regression: every traffic pattern x seeds, for each controller build.
# `make regress` builds the binaries and calls this script.
#   RUNS  space-separated "name=binary:seeds" items, one per controller build
# Each run appends one line to $OUT/regress.csv. A passing run's log is
# deleted; a failing run keeps its log in $OUT.
set -u

OUT=${OUT:-build/regress}
N=${N:-2000}
PATTERNS=${PATTERNS:-"seq rowhit mixed rand hotbank stride"}
RUNS=${RUNS:-"default=obj_dir_rand/sim_rand:20"}

mkdir -p "$OUT"
rm -f "$OUT"/regress.csv "$OUT"/*.log

runs=0
fails=0
for item in $RUNS; do
  name=${item%%=*}
  rest=${item#*=}
  bin=${rest%%:*}
  seeds=${rest##*:}
  for p in $PATTERNS; do
    for s in $(seq 1 "$seeds"); do
      runs=$((runs + 1))
      log="$OUT/${name}_${p}_seed${s}.log"
      if "$bin" +CONFIG="$name" +PATTERN="$p" +SEED="$s" +N="$N" +CSV="$OUT/regress.csv" > "$log" 2>&1; then
        rm -f "$log"
      else
        fails=$((fails + 1))
        echo "FAIL config=$name pattern=$p seed=$s -> $log"
      fi
    done
  done
done

echo "regress: $runs runs, $((runs - fails)) passed, $fails failed"
[ "$fails" -eq 0 ]
