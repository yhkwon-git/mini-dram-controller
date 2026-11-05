#!/usr/bin/env bash
# Area and timing of mem_ctrl: sv2v -> Yosys (Nangate45 typical) -> OpenSTA.
# `make ppa` runs it from the repository root; results go to $OUT.
#   SV2V  sv2v binary                 (default: sv2v)
#   LIB   Nangate45 typical .lib[.gz] (default: the OpenSTA example library)
# The numbers are for comparing versions: no wires, no clock tree, typical corner.
set -euo pipefail

OUT=${OUT:-build/ppa}
SV2V=${SV2V:-sv2v}
LIB=${LIB:-$HOME/src/OpenSTA/examples/nangate45_typ.lib.gz}
SRCS=(rtl/dram_pkg.sv rtl/mc_queue.sv rtl/mc_bank.sv rtl/mc_chan.sv rtl/mc_refresh.sv
      rtl/mc_sched.sv rtl/mc_resp.sv rtl/mem_ctrl.sv)

mkdir -p "$OUT"
case "$LIB" in
  *.gz) gunzip -c "$LIB" > "$OUT/nangate45_typ.lib" ;;
  *)    cp "$LIB" "$OUT/nangate45_typ.lib" ;;
esac

"$SV2V" "${SRCS[@]}" > "$OUT/mem_ctrl.v"

yosys -q -l "$OUT/yosys.log" -p "
  read_verilog $OUT/mem_ctrl.v;
  hierarchy -check -top mem_ctrl;
  synth -top mem_ctrl -flatten;
  tee -q -o $OUT/stat_generic.txt stat;
  dfflibmap -liberty $OUT/nangate45_typ.lib;
  abc -liberty $OUT/nangate45_typ.lib;
  opt_clean -purge;
  tee -q -o $OUT/stat_nangate.txt stat -liberty $OUT/nangate45_typ.lib;
  write_verilog -noattr -noexpr $OUT/mem_ctrl_nangate.v"

sed -e "s#@LIB@#$OUT/nangate45_typ.lib#" -e "s#@NET@#$OUT/mem_ctrl_nangate.v#" syn/sta.tcl > "$OUT/sta.tcl"
sta -no_splash -exit "$OUT/sta.tcl" > "$OUT/sta.log" 2>&1

area=$(grep -m1 "Chip area" "$OUT/stat_nangate.txt" | awk '{print $NF}')
cells=$(grep -m1 "Number of cells" "$OUT/stat_nangate.txt" | awk '{print $NF}')
ffs=$(grep -E '^ +DFF[A-Z]*_X[0-9]+ ' "$OUT/stat_nangate.txt" | awk '{s += $2} END {print s + 0}')
arrival=$(awk '/^=== reg2reg/ {r = 1} r && /data arrival time/ {print $1; exit}' "$OUT/sta.log")
slack=$(awk '/^=== reg2reg/ {r = 1} r && /slack/ {print $1; exit}' "$OUT/sta.log")
power=$(awk '/^Total/ {print $(NF-1); exit}' "$OUT/sta.log")

echo "area_um2,cells,ff,reg2reg_ns,min_period_ns,fmax_mhz,power_w_500mhz" > "$OUT/ppa.csv"
awk -v a="$area" -v c="$cells" -v f="$ffs" -v r="$arrival" -v s="$slack" -v p="$power" 'BEGIN {
  period = 10.0 - s
  printf "%.0f,%d,%d,%.3f,%.3f,%.0f,%s\n", a, c, f, r, period, 1000.0 / period, p
}' >> "$OUT/ppa.csv"
column -s, -t "$OUT/ppa.csv"
