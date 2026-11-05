#!/usr/bin/env python3
"""Summarize the random-regression CSV written by tb/run_regress.sh.

    python3 tools/regress_report.py build/regress/regress.csv [--plots DIR]

Prints Markdown tables: checks per traffic pattern, the performance baseline
per pattern, and the functional-coverage bins summed over all runs.
--plots DIR also writes PNG charts there (needs matplotlib).
"""
import argparse
import csv
import statistics
import sys
from collections import OrderedDict

PATTERN_ORDER = ["seq", "rowhit", "mixed", "rand", "hotbank", "stride"]


def load(path):
    with open(path, newline="") as fh:
        return list(csv.DictReader(fh))


def group(rows):
    names = PATTERN_ORDER + sorted({r["pattern"] for r in rows} - set(PATTERN_ORDER))
    out = OrderedDict()
    for name in names:
        runs = [r for r in rows if r["pattern"] == name]
        if runs:
            out[name] = runs
    return out


def mean(runs, key):
    return statistics.fmean(float(r[key]) for r in runs)


def total(runs, key):
    return sum(int(r[key]) for r in runs)


def checks_table(groups):
    print("| pattern | runs | requests | PASS | data mismatches | protocol violations | waived (known gaps) |")
    print("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
    for name, runs in groups.items():
        passed = sum(r["result"] == "PASS" for r in runs)
        print(f"| {name} | {len(runs)} | {total(runs, 'n'):,} | {passed}/{len(runs)} | "
              f"{total(runs, 'mismatches')} | {total(runs, 'violations')} | {total(runs, 'waived'):,} |")


def perf_table(groups):
    print("| pattern | row hit % | data bus busy % | latency avg | latency p99 | REF interval avg | peak REF debt |")
    print("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
    for name, runs in groups.items():
        print(f"| {name} | {mean(runs, 'hit_pct'):.1f} | {mean(runs, 'util_pct'):.1f} | "
              f"{mean(runs, 'lat_avg'):.1f} | {mean(runs, 'lat_p99'):.1f} | "
              f"{mean(runs, 'ref_int_avg'):.1f} | {max(int(r['ref_debt_max']) for r in runs)} |")


def coverage_table(rows):
    bins = [k for k in rows[0] if k.startswith("cv_")]
    hit_bins = 0
    print("| bin | hits, all runs | runs that hit it |")
    print("| --- | ---: | ---: |")
    for b in bins:
        hits = total(rows, b)
        runs = sum(int(r[b]) > 0 for r in rows)
        hit_bins += hits > 0
        print(f"| {b[3:]} | {hits:,} | {runs}/{len(rows)} |")
    print(f"\nfunctional bins hit: {hit_bins}/{len(bins)}")


def config_table(rows):
    """One line per controller build: checks, and data bus busy / latency averaged over patterns.
    CSVs from v3 on also carry read latency and RD<->WR turnarounds."""
    configs = list(OrderedDict.fromkeys(r.get("config", "default") for r in rows))
    v3 = "rd_lat_avg" in rows[0]
    extra_h = " read latency avg | turnarounds |" if v3 else ""
    extra_a = " ---: | ---: |" if v3 else ""
    print("| build | runs | PASS | data mismatches | violations | data bus busy % | latency avg |" + extra_h)
    print("| --- | ---: | ---: | ---: | ---: | ---: | ---: |" + extra_a)
    for c in configs:
        runs = [r for r in rows if r.get("config", "default") == c]
        groups = list(group(runs).values())
        busy = statistics.fmean(mean(g, "util_pct") for g in groups)
        lat = statistics.fmean(mean(g, "lat_avg") for g in groups)
        passed = sum(r["result"] == "PASS" for r in runs)
        extra = ""
        if v3:
            rd_lat = statistics.fmean(mean(g, "rd_lat_avg") for g in groups)
            turns = statistics.fmean(mean(g, "turns") for g in groups)
            extra = f" {rd_lat:.1f} | {turns:,.0f} |"
        print(f"| {c} | {len(runs)} | {passed}/{len(runs)} | {total(runs, 'mismatches')} | "
              f"{total(runs, 'violations')} | {busy:.1f} | {lat:.1f} |" + extra)


def plots(groups, outdir, baseline=None, base_label="v1", label="v2", compare_name="regress_v1_v2.png"):
    try:
        import plot_regress  # tools/plot_regress.py
    except ImportError as exc:
        sys.exit(f"--plots needs matplotlib: {exc}")
    plot_regress.draw(groups, outdir)
    if baseline:
        base = {r["pattern"]: r for r in load(baseline)}
        plot_regress.draw_compare(groups, base, outdir, name=compare_name,
                                  base_label=base_label, new_label=label)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("csv")
    ap.add_argument("--plots", metavar="DIR")
    ap.add_argument("--baseline", metavar="CSV",
                    help="per-pattern means of an earlier controller; adds a comparison chart")
    ap.add_argument("--baseline-label", default="v1")
    ap.add_argument("--label", default="v2", help="name of this run in the comparison chart")
    ap.add_argument("--compare-name", default="regress_v1_v2.png", help="file name of the comparison chart")
    args = ap.parse_args()
    rows = load(args.csv)
    if not rows:
        sys.exit(f"{args.csv}: no runs")
    default = [r for r in rows if r.get("config", "default") == "default"] or rows
    groups = group(default)
    runs = len(rows)
    passed = sum(r["result"] == "PASS" for r in rows)
    print(f"{runs} runs, {sum(int(r['n']) for r in rows):,} requests, {passed} PASS, {runs - passed} FAIL\n")
    config_table(rows)
    print("\ndefault build, per pattern:\n")
    checks_table(groups)
    print()
    perf_table(groups)
    print("\nall builds:\n")
    coverage_table(rows)
    if args.plots:
        plots(groups, args.plots, args.baseline, args.baseline_label, args.label, args.compare_name)


if __name__ == "__main__":
    main()
