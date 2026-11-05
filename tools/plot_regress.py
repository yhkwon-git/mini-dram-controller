"""PNG chart for tools/regress_report.py --plots (needs matplotlib).

One figure, four panels in the same pattern order: row hit rate, data bus busy,
latency (average and p99), and the average REF interval against tREFI. Each
value is the mean over all seeds of a pattern. The exact numbers are in the
tables that regress_report.py prints.
"""
import os
import statistics

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
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


def _frame(ax, title, xmax, step):
    ax.set_facecolor(SURFACE)
    ax.set_title(title, loc="left", fontsize=11, color=INK, fontweight="semibold", pad=10)
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


def _bars(ax, values, color):
    """Horizontal bars, square at the baseline, 4 px rounded at the data end.

    Each bar is one rounded shape that starts left of the baseline; the axes
    clip it at x = 0, which squares that end without a second, seamed patch.
    """
    ux, uy = _units_per_px(ax)
    h = min(0.62, 22 * uy)  # never thicker than 22 px
    r = 4 * ux
    for i, v in enumerate(values):
        y = i - h / 2
        if v > r:
            ax.add_patch(FancyBboxPatch((-2 * r, y), v + 2 * r, h,
                                        boxstyle=f"round,pad=0,rounding_size={r}",
                                        mutation_aspect=uy / ux, facecolor=color, edgecolor="none",
                                        zorder=2))
        else:
            ax.add_patch(Rectangle((0, y), v, h, facecolor=color, edgecolor="none", zorder=2))


def draw(groups, outdir, name="regress_baseline.png"):
    names = list(groups)
    ys = list(range(len(names)))
    runs = sum(len(v) for v in groups.values())
    seeds = max(len(v) for v in groups.values())
    n = int(next(iter(groups.values()))[0]["n"])

    plt.rcParams["font.family"] = ["Segoe UI", "Helvetica Neue", "Arial", "DejaVu Sans"]
    fig, axes = plt.subplots(2, 2, figsize=(10, 6.8), facecolor=SURFACE)
    fig.subplots_adjust(left=0.09, right=0.97, top=0.83, bottom=0.07, wspace=0.28, hspace=0.55)
    fig.text(0.02, 0.955, "Random regression baseline, v1 controller", fontsize=14,
             fontweight="semibold", color=INK)
    fig.text(0.02, 0.915, f"Mean of {seeds} seeds per pattern, {n:,} requests per run "
             f"({runs} runs). One command per cycle, one read in flight.",
             fontsize=10, color=INK_2)

    panels = [
        (axes[0][0], "Row hit rate, %", [_mean(groups[p], "hit_pct") for p in names], 100, 20),
        (axes[0][1], "Data bus busy, % of cycles", [_mean(groups[p], "util_pct") for p in names], 40, 10),
        (axes[1][1], "REF interval, average cycles", [_mean(groups[p], "ref_int_avg") for p in names],
         160, 40),
    ]
    for ax, title, values, xmax, step in panels:
        _frame(ax, title, xmax, step)
    lat = axes[1][0]
    _frame(lat, "Latency, accept to response, cycles", 100, 20)

    for ax in axes.flat:
        ax.set_ylim(len(names) - 0.5, -0.5)
        ax.set_yticks(ys)
        ax.set_yticklabels(names)
    fig.canvas.draw()  # final layout before measuring pixels per unit

    for ax, _title, values, _xmax, _step in panels:
        _bars(ax, values, SERIES_1)

    ref = axes[1][1]
    ref.axvline(TREFI, color=INK_2, linewidth=1.2, zorder=3)
    ref.text(TREFI, 1.02, f"tREFI = {TREFI}", transform=ref.get_xaxis_transform(), ha="center",
             va="bottom", color=INK_2, fontsize=9)
    ref.set_title("REF interval, average cycles", loc="left", fontsize=11, color=INK,
                  fontweight="semibold", pad=26)

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
    lat.set_title("Latency, accept to response, cycles", loc="left", fontsize=11, color=INK,
                  fontweight="semibold", pad=26)

    os.makedirs(outdir, exist_ok=True)
    path = os.path.join(outdir, name)
    fig.savefig(path, dpi=DPI, facecolor=SURFACE)
    plt.close(fig)
    print(f"wrote {path}")
