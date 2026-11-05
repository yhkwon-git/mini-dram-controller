#!/usr/bin/env python3
"""Traffic x build matrix and per-build area/timing for docs/analysis.md.

    python3 tools/matrix_report.py LOAD_CSV SAT_CSV [--plots DIR]
    python3 tools/matrix_report.py --ppa build/ppa_sweep [--load LOAD_CSV]

LOAD_CSV and SAT_CSV come from `make matrix` (the regression load, and
saturated: no request gap, no back-pressure). The first form prints Markdown
tables per build and pattern; --plots also writes a heatmap PNG (needs
matplotlib). --ppa prints area and timing of each build's parameters from
`make ppa-sweep`, and with --load the throughput and latency next to them.
"""
import argparse
import csv
import os
import statistics
import sys

PATTERNS = ["seq", "rowhit", "mixed", "rand", "hotbank", "stride", "stride64"]
BUILDS = ["default", "bus1", "refab", "bus1_refab", "rfm_late", "nodrain", "fcfs",
          "fcfs_nodrain", "close", "timer", "map_rbc", "map_rcb", "map_brc", "depth4",
          "rdpipe1", "starve24"]

# Single-hue sequential ramp (light -> dark) and ink, from the dataviz palette
SURFACE = "#fcfcfb"
RAMP = ["#eef4fc", "#d4e3f8", "#b3cef2", "#8db5ea", "#5f96df", "#2a78d6", "#1f5fae", "#174884"]
INK_1 = "#1d1d1b"
INK_2 = "#5c5c58"
INK_ON_DARK = "#ffffff"


def load(path):
    with open(path, newline="") as fh:
        return list(csv.DictReader(fh))


def cell(rows, build, pattern, key):
    vals = [float(r[key]) for r in rows if r["config"] == build and r["pattern"] == pattern]
    return statistics.fmean(vals) if vals else None


def builds_in(rows):
    have = {r["config"] for r in rows}
    return [b for b in BUILDS if b in have] + sorted(have - set(BUILDS))


def table(rows, key, title, fmt="{:.1f}"):
    pats = [p for p in PATTERNS if any(r["pattern"] == p for r in rows)]
    print(f"\n{title}\n")
    print("| build | " + " | ".join(pats) + " | avg |")
    print("| --- |" + " ---: |" * (len(pats) + 1))
    for b in builds_in(rows):
        vals = [cell(rows, b, p, key) for p in pats]
        avg = statistics.fmean(v for v in vals if v is not None)
        print(f"| {b} | " + " | ".join(fmt.format(v) for v in vals) + f" | {fmt.format(avg)} |")


def check_pass(rows, label):
    fails = [r for r in rows if r["result"] != "PASS"]
    print(f"{label}: {len(rows)} runs, {len(rows) - len(fails)} PASS, "
          f"{sum(int(r['violations']) for r in rows)} violations, "
          f"{sum(int(r['mismatches']) for r in rows)} mismatches")


def heatmap(load_rows, sat_rows, outdir):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError as exc:
        sys.exit(f"--plots needs matplotlib: {exc}")
    plt.rcParams["font.family"] = ["Segoe UI", "Arial", "DejaVu Sans"]
    panels = [(load_rows, "Random load (gap 0-2 cycles, back-pressure)"),
              (sat_rows, "Saturated (no gap, no back-pressure)")]
    builds = builds_in(load_rows)
    fig, axes = plt.subplots(1, 2, figsize=(13, 0.42 * len(builds) + 2.2), facecolor=SURFACE)
    fig.subplots_adjust(left=0.1, right=0.99, top=0.84, bottom=0.04, wspace=0.08)
    fig.text(0.01, 0.965, "Data bus busy, % of cycles, by build and traffic", fontsize=15,
             color=INK_1, weight="semibold", va="top")
    fig.text(0.01, 0.915, "Each build changes one parameter of the v4 default; darker is busier within a panel "
             "(each panel has its own scale). Mean of the seeds per cell.", fontsize=10.5, color=INK_2, va="top")
    for ax, (rows, title) in zip(axes, panels):
        pats = [p for p in PATTERNS if any(r["pattern"] == p for r in rows)]
        vals = [[cell(rows, b, p, "util_pct") for p in pats] for b in builds]
        flat = [v for row in vals for v in row if v is not None]
        lo, hi = min(flat), max(flat)
        ax.set_facecolor(SURFACE)
        for i, row in enumerate(vals):
            for j, v in enumerate(row):
                k = min(len(RAMP) - 1, int((v - lo) / (hi - lo + 1e-9) * len(RAMP)))
                ax.add_patch(plt.Rectangle((j, i), 1, 1, facecolor=RAMP[k],
                                           edgecolor=SURFACE, linewidth=2))
                ax.text(j + 0.5, i + 0.5, f"{v:.1f}", ha="center", va="center", fontsize=9,
                        color=INK_ON_DARK if k >= 5 else INK_1)
        ax.set_xlim(0, len(pats))
        ax.set_ylim(len(builds), 0)
        ax.set_xticks([j + 0.5 for j in range(len(pats))])
        ax.set_xticklabels(pats, fontsize=9.5, color=INK_2)
        ax.xaxis.tick_top()
        ax.set_yticks([i + 0.5 for i in range(len(builds))])
        ax.set_yticklabels(builds if ax is axes[0] else [], fontsize=9.5, color=INK_2)
        ax.tick_params(length=0)
        for side in ax.spines.values():
            side.set_visible(False)
        ax.set_title(title, fontsize=11, color=INK_1, loc="left", pad=24)
    os.makedirs(outdir, exist_ok=True)
    path = os.path.join(outdir, "matrix_busy.png")
    fig.savefig(path, dpi=150, facecolor=SURFACE)
    print(f"wrote {path}")


def ppa(dirpath, load_csv):
    rows = {}
    for b in BUILDS:
        f = os.path.join(dirpath, b, "ppa.csv")
        if os.path.exists(f):
            rows[b] = load(f)[0]
    if "default" not in rows:
        sys.exit(f"{dirpath}/default/ppa.csv missing; run make ppa-sweep")
    base = rows["default"]
    perf = None
    if load_csv:
        lr = load(load_csv)
        pats = [p for p in PATTERNS if any(r["pattern"] == p for r in lr)]
        perf = {b: (statistics.fmean(cell(lr, b, p, "util_pct") for p in pats),
                    statistics.fmean(cell(lr, b, p, "rd_lat_avg") for p in pats))
                for b in builds_in(lr)}
    head = "| build | area (µm²) | FF | reg2reg (ns) | fmax (MHz) | Δ area | Δ FF | Δ fmax |"
    sep = "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
    if perf:
        head += " busy (load) | read latency |"
        sep += " ---: | ---: |"
    print(head)
    print(sep)
    for b, r in rows.items():
        area, ff, fmax = float(r["area_um2"]), int(r["ff"]), float(r["fmax_mhz"])
        da = 100.0 * (area / float(base["area_um2"]) - 1.0)
        dff = ff - int(base["ff"])
        dfm = 100.0 * (fmax / float(base["fmax_mhz"]) - 1.0)
        line = (f"| {b} | {area:,.0f} | {ff:,} | {float(r['reg2reg_ns']):.3f} | {fmax:.0f} | "
                f"{da:+.1f}% | {dff:+d} | {dfm:+.1f}% |")
        if perf and b in perf:
            line += f" {perf[b][0]:.1f}% | {perf[b][1]:.1f} |"
        print(line)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("csv", nargs="*")
    ap.add_argument("--plots", metavar="DIR")
    ap.add_argument("--ppa", metavar="DIR")
    ap.add_argument("--load", metavar="CSV", help="with --ppa: matrix load CSV for busy/latency")
    args = ap.parse_args()
    if args.ppa:
        ppa(args.ppa, args.load)
        return
    if len(args.csv) != 2:
        sys.exit("give LOAD_CSV and SAT_CSV (from make matrix)")
    load_rows, sat_rows = load(args.csv[0]), load(args.csv[1])
    check_pass(load_rows, "load")
    check_pass(sat_rows, "saturated")
    table(load_rows, "util_pct", "Data bus busy %, random load")
    table(load_rows, "rd_lat_avg", "Read latency (average cycles), random load")
    table(load_rows, "lat_p99", "Latency p99 (cycles), random load", "{:.0f}")
    table(load_rows, "hit_pct", "Row hit rate %, random load")
    table(sat_rows, "util_pct", "Data bus busy %, saturated")
    table(sat_rows, "rd_lat_avg", "Read latency (average cycles), saturated")
    if args.plots:
        heatmap(load_rows, sat_rows, args.plots)


if __name__ == "__main__":
    main()
