#!/usr/bin/env bash
# Random regression: every traffic pattern x seeds, for each controller build.
# `make regress` builds the binaries and calls this script.
#   RUNS  space-separated "name=binary:seeds" items, one per controller build
#   JOBS  runs at once (default: the number of CPUs)
# Each run writes its own CSV line; the lines are joined into
# $OUT/regress.csv in job order. A passing run's log is deleted; a failing
# run keeps its log in $OUT.
set -u

OUT=${OUT:-build/regress}
N=${N:-2000}
PATTERNS=${PATTERNS:-"seq rowhit mixed rand hotbank stride"}
RUNS=${RUNS:-"default=obj_dir_rand/sim_rand:20"}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 1)}

mkdir -p "$OUT/runs"
rm -f "$OUT"/regress.csv "$OUT"/*.log "$OUT"/runs/*

jobs_file="$OUT/runs/jobs.txt"
: > "$jobs_file"
for item in $RUNS; do
  name=${item%%=*}
  rest=${item#*=}
  bin=${rest%%:*}
  seeds=${rest##*:}
  for p in $PATTERNS; do
    for s in $(seq 1 "$seeds"); do
      echo "$name $bin $p $s" >> "$jobs_file"
    done
  done
done

run_one() {
  local name=$1 bin=$2 p=$3 s=$4
  local log="$OUT/${name}_${p}_seed${s}.log"
  if "$bin" +CONFIG="$name" +PATTERN="$p" +SEED="$s" +N="$N" \
       +CSV="$OUT/runs/${name}_${p}_${s}.csv" > "$log" 2>&1; then
    rm -f "$log"
  else
    echo "FAIL config=$name pattern=$p seed=$s -> $log"
  fi
}
export -f run_one
export OUT N

xargs -P "$JOBS" -L 1 bash -c 'run_one "$@"' _ < "$jobs_file"

# One header, then every run's line in job order
first=1
while read -r name _ p s; do
  f="$OUT/runs/${name}_${p}_${s}.csv"
  [ -f "$f" ] || continue
  if [ "$first" -eq 1 ]; then
    head -n 1 "$f" > "$OUT/regress.csv"
    first=0
  fi
  tail -n +2 "$f" >> "$OUT/regress.csv"
done < "$jobs_file"

runs=$(wc -l < "$jobs_file")
fails=$(find "$OUT" -maxdepth 1 -name '*.log' | wc -l)
echo "regress: $runs runs, $((runs - fails)) passed, $fails failed"
[ "$fails" -eq 0 ]
