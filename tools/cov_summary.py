#!/usr/bin/env python3
"""Per-module code coverage from Verilator coverage.dat files.

    python3 tools/cov_summary.py build/cov/*.dat
    python3 tools/cov_summary.py --holes mem_ctrl build/cov/*.dat

Points are merged by source location and kind, without the instance path, so
runs from different testbench tops add up. A point counts as covered when any
run hit it. Only modules under rtl/ are reported. --holes MODULE lists the
line, branch and expression points of MODULE that no run reached.
"""
import sys
from collections import defaultdict

KINDS = [("line", "Line"), ("branch", "Branch"), ("expr", "Expr"), ("toggle", "Toggle")]
MODULE_ORDER = ["mem_ctrl", "mc_queue", "mc_xage", "mc_wdrain", "mc_sched", "mc_bank", "mc_chan",
                "mc_refresh", "mc_resp", "dram_model", "mem_ctrl_top", "host_if"]


def points(path):
    """Yield (fields, count) for every coverage point in one .dat file."""
    with open(path, encoding="latin-1") as fh:
        for raw in fh:
            if not raw.startswith("C '"):
                continue
            body, _, count = raw.rstrip("\n").rpartition("' ")
            fields = {}
            for item in body[3:].split("\x01"):
                if item:
                    key, _, value = item.partition("\x02")
                    fields[key] = value
            yield fields, int(count)


def merge(paths):
    covered = {}
    for path in paths:
        for f, count in points(path):
            src = f.get("f", "")
            if not src.startswith("rtl/"):
                continue
            kind, _, module = f.get("page", "").partition("/")
            kind = kind[2:] if kind.startswith("v_") else kind
            # Verilator names a module built with explicit parameters "name__D8";
            # fold those copies into the module they came from.
            module = module.split("__")[0]
            key = (module, kind, src, f.get("l"), f.get("n"), f.get("o"))
            covered[key] = covered.get(key, False) or count > 0
    return covered


def collect(covered):
    totals = defaultdict(lambda: [0, 0])  # (module, kind) -> [covered, points]
    for (module, kind, *_), hit in covered.items():
        totals[(module, kind)][0] += int(hit)
        totals[(module, kind)][1] += 1
    return totals


def cell(hit, total):
    return f"{100.0 * hit / total:.1f}% ({hit}/{total})" if total else "-"


def holes(covered, module):
    print(f"unreached line / branch / expr points in {module}:")
    misses = sorted((int(l), kind, src, o) for (m, kind, src, l, _n, o), hit in covered.items()
                    if m == module and kind != "toggle" and not hit)
    for line, kind, src, comment in misses:
        print(f"  {src}:{line}  {kind:6}  {comment}")


def main(args):
    module = None
    if args[:1] == ["--holes"]:
        module, args = args[1], args[2:]
    if not args:
        sys.exit(__doc__)
    paths = args
    covered = merge(paths)
    if module:
        holes(covered, module)
        return
    totals = collect(covered)
    modules = sorted({m for m, _ in totals},
                     key=lambda m: (MODULE_ORDER.index(m) if m in MODULE_ORDER else 99, m))
    print(f"coverage from {len(paths)} run(s)")
    print("| module | " + " | ".join(name for _, name in KINDS) + " |")
    print("| --- |" + " ---: |" * len(KINDS))
    for m in modules:
        print(f"| `{m}` | " + " | ".join(cell(*totals[(m, k)]) for k, _ in KINDS) + " |")
    ctrl = [m for m in modules if m == "mem_ctrl" or m.startswith("mc_")]
    if ctrl:
        row = [cell(sum(totals[(m, k)][0] for m in ctrl), sum(totals[(m, k)][1] for m in ctrl))
               for k, _ in KINDS]
        print("| controller (`mem_ctrl` + `mc_*`) | " + " | ".join(row) + " |")
    all_rtl = [cell(sum(totals[(m, k)][0] for m in modules), sum(totals[(m, k)][1] for m in modules))
               for k, _ in KINDS]
    print("| RTL total | " + " | ".join(all_rtl) + " |")


if __name__ == "__main__":
    main(sys.argv[1:])
