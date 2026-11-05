"""PNG charts for tools/regress_report.py --plots (needs matplotlib).

draw():         four panels in the same pattern order: row hit rate, data bus
                busy, latency (average and p99), and the average refresh interval per bank
                against tREFI.
draw_compare(): the same measures for a baseline (an earlier controller) and
                the current one, as paired bars.

Each value is the mean over all seeds of a pattern. The exact numbers are in
the tables that regress_report.py prints.
"""
import os
import statistics

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.lines import Line2D  # noqa: E402
from matplotlib.patches import FancyBboxPatch, Rectangle  # noqa: E402

# Light chart surface and slots 1-2 of the reference categorical palette
SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK_2 = "#52514e"
MUTED = "#898781"
GRID = "#e1e0d9"
AXIS = "#c3c2b7"
SERIES_1 = "#2a78d6"
SERIES_2 = "#eb6834"
TREFI = 64
DPI = 150


def _mean(runs, key):
    return statistics.fmean(float(r[key]) for r in runs)


def _frame(ax, title, xmax, step, pad=10):
    ax.set_facecolor(SURFACE)
    ax.set_title(title, loc="left", fontsize=11, color=INK, fontweight="semibold", pad=pad)
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)
    ax.spines["bottom"].set_color(AXIS)
    ax.spines["bottom"].set_linewidth(1)
    ax.tick_params(axis="x", colors=MUTED, labelsize=9, length=0, pad=6)
    ax.tick_params(axis="y", colors=INK_2, labelsize=10, length=0, pad=8)
    ax.grid(axis="x", color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    ax.set_xlim(0, xmax)
    ax.set_xticks(range(0, xmax + 1, step))


def _units_per_px(ax):
    box = ax.get_window_extent()
    x0, x1 = ax.get_xlim()
    y0, y1 = ax.get_ylim()
    return (x1 - x0) / box.width, abs(y1 - y0) / box.height


def _bar(ax, y, v, h, color):
    """One horizontal bar centred on y: square at the baseline, 4 px rounded at the data end.

    The rounded shape starts left of the baseline and the axes clip it at x = 0,
    which squares that end without a second, seamed patch.
    """
    ux, uy = _units_per_px(ax)
    r = 4 * ux
    if v > r:
        ax.add_patch(FancyBboxPatch((-2 * r, y - h / 2), v + 2 * r, h,
                                    boxstyle=f"round,pad=0,rounding_size={r}",
                                    mutation_aspect=uy / ux, facecolor=color, edgecolor="none",
                                    zorder=2))
    else:
        ax.add_patch(Rectangle((0, y - h / 2), v, h, facecolor=color, edgecolor="none", zorder=2))


def _bars(ax, values, color):
    _, uy = _units_per_px(ax)
    h = min(0.62, 22 * uy)  # never thicker than 22 px
    for i, v in enumerate(values):
        _bar(ax, i, v, h, color)


def _rows(fig, axes, names):
    ys = list(range(len(names)))
    for ax in axes.flat:
        ax.set_ylim(len(names) - 0.5, -0.5)
        ax.set_yticks(ys)
        ax.set_yticklabels(names)
    fig.canvas.draw()  # final layout before measuring pixels per unit
    return ys


def _tREFI_line(ax):
    ax.axvline(TREFI, color=INK_2, linewidth=1.2, zorder=3)
    ax.text(TREFI, 1.02, f"tREFI = {TREFI}", transform=ax.get_xaxis_transform(), ha="center",
            va="bottom", color=INK_2, fontsize=9)


def _save(fig, outdir, name):
    os.makedirs(outdir, exist_ok=True)
    path = os.path.join(outdir, name)
    fig.savefig(path, dpi=DPI, facecolor=SURFACE)
    plt.close(fig)
    print(f"wrote {path}")


def _header(fig, title, subtitle):
    fig.text(0.02, 0.955, title, fontsize=14, fontweight="semibold", color=INK)
    fig.text(0.02, 0.915, subtitle, fontsize=10, color=INK_2)


def draw(groups, outdir, name="regress_baseline.png"):
    names = list(groups)
    seeds = max(len(v) for v in groups.values())
    n = int(next(iter(groups.values()))[0]["n"])

    plt.rcParams["font.family"] = ["Segoe UI", "Helvetica Neue", "Arial", "DejaVu Sans"]
    fig, axes = plt.subplots(2, 2, figsize=(10, 6.8), facecolor=SURFACE)
    fig.subplots_adjust(left=0.09, right=0.97, top=0.83, bottom=0.07, wspace=0.28, hspace=0.55)
    _header(fig, "Random regression baseline",
            f"Mean of {seeds} seeds per pattern, {n:,} requests per run, request gap 0-2 cycles.")

    panels = [
        (axes[0][0], "Row hit rate, %", "hit_pct", 100, 20),
        (axes[0][1], "Data bus busy, % of cycles", "util_pct", 40, 10),
        (axes[1][1], "Refresh interval per bank, average cycles", "ref_int_avg", 160, 40),
    ]
    for ax, title, _key, xmax, step in panels:
        _frame(ax, title, xmax, step, pad=26 if ax is axes[1][1] else 10)
    lat = axes[1][0]
    _frame(lat, "Latency, accept to response, cycles", 160, 40, pad=26)
    ys = _rows(fig, axes, names)

    for ax, _title, key, _xmax, _step in panels:
        _bars(ax, [_mean(groups[p], key) for p in names], SERIES_1)
    _tREFI_line(axes[1][1])

    avg = [_mean(groups[p], "lat_avg") for p in names]
    p99 = [_mean(groups[p], "lat_p99") for p in names]
    for y, a, p in zip(ys, avg, p99):
        lat.plot([a, p], [y, y], color=AXIS, linewidth=2, solid_capstyle="round", zorder=2)
    lat.scatter(avg, ys, s=70, color=SERIES_1, edgecolors=SURFACE, linewidths=2, zorder=3,
                label="average")
    lat.scatter(p99, ys, s=70, color=SERIES_2, edgecolors=SURFACE, linewidths=2, zorder=3,
                label="99th percentile")
    leg = lat.legend(loc="lower left", bbox_to_anchor=(0.0, 1.06), ncol=2, frameon=False,
                     fontsize=9, handletextpad=0.3, columnspacing=1.2, borderaxespad=0)
    for text in leg.get_texts():
        text.set_color(INK_2)
    _save(fig, outdir, name)


def draw_compare(groups, baseline, outdir, name="regress_v1_v2.png",
                 base_label="v1", new_label="v2"):
    """Paired bars per pattern: baseline (slot 2) above, current (slot 1) below."""
    names = [p for p in groups if p in baseline]
    seeds = max(len(groups[p]) for p in names)
    n = int(groups[names[0]][0]["n"])

    plt.rcParams["font.family"] = ["Segoe UI", "Helvetica Neue", "Arial", "DejaVu Sans"]
    fig, axes = plt.subplots(2, 2, figsize=(10, 7.2), facecolor=SURFACE)
    fig.subplots_adjust(left=0.09, right=0.97, top=0.80, bottom=0.07, wspace=0.28, hspace=0.55)
    _header(fig, f"{base_label} and {new_label} under the same random traffic",
            f"Mean of {seeds} seeds per pattern, {n:,} requests per run, request gap 0-2 cycles.")

    # Latency axis: at least 120, and room past the longest bar
    lat_top = max([float(baseline[p]["lat_avg"]) for p in names] +
                  [_mean(groups[p], "lat_avg") for p in names])
    lat_max = max(120, 20 * (int(lat_top + 5) // 20 + 1))
    panels = [
        (axes[0][0], "Data bus busy, % of cycles", "util_pct", 40, 10),
        (axes[0][1], "Refresh interval per bank, average cycles", "ref_int_avg", 160, 40),
        (axes[1][0], "Row hit rate, %", "hit_pct", 100, 20),
        (axes[1][1], "Latency, average cycles", "lat_avg", lat_max, 20 if lat_max <= 120 else 40),
    ]
    for ax, title, _key, xmax, step in panels:
        _frame(ax, title, xmax, step, pad=22 if ax in (axes[0][0], axes[0][1]) else 10)
    _rows(fig, axes, names)
    _, uy = _units_per_px(axes[0][0])
    h = min(0.34, 12 * uy)
    for ax, _title, key, _xmax, _step in panels:
        for i, p in enumerate(names):
            _bar(ax, i - 0.19, float(baseline[p][key]), h, SERIES_2)
            _bar(ax, i + 0.19, _mean(groups[p], key), h, SERIES_1)
    _tREFI_line(axes[0][1])

    handles = [Line2D([0], [0], color=SERIES_2, linewidth=8, label=base_label),
               Line2D([0], [0], color=SERIES_1, linewidth=8, label=new_label)]
    leg = fig.legend(handles=handles, loc="upper right", bbox_to_anchor=(0.97, 0.975), ncol=2,
                     frameon=False, fontsize=10, handlelength=1.2, columnspacing=1.6)
    for text in leg.get_texts():
        text.set_color(INK_2)
    _save(fig, outdir, name)
