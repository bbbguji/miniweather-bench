#!/usr/bin/env python3
"""
Post-process miniWeather baseline runs (CPU + GPU variants).

Produces report-ready plots:
  overview.png         -- Single master figure: best-in-class per size
                          for each hardware family (CPU 1N, CPU 2N, GPU 1N, GPU 2N).
  scaling_<size>.png   -- Per-size strong scaling: CPU panel + GPU panel,
                          minimal lines (hybrid omitted, redundant with mpi).

Usage:
    python3 scripts/analyze.py
    python3 scripts/analyze.py --csv path/to/runs.csv --out path/to/plots/
"""

import argparse, sys
from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


CPU_VARIANTS = ["serial", "mpi", "mpi_2node", "openmp", "hybrid", "hybrid_2node"]
GPU_VARIANTS = ["openmp45", "openmp45_2node", "openacc", "openacc_2node"]

# Scaling plot styles (hybrid omitted — overlaps with mpi)
CPU_STYLES = {
    "serial":     ("#888888", "o", "-",  "serial"),
    "openmp":     ("#1f77b4", "o", "-",  "OpenMP (1 node)"),
    "mpi":        ("#ff7f0e", "s", "-",  "MPI (1 node)"),
    "mpi_2node":  ("#d62728", "D", "--", "MPI (2 nodes)"),
}
GPU_STYLES = {
    "openmp45":       ("#17becf", "o", "-",  "OpenMP target (1 node)"),
    "openmp45_2node": ("#1f77b4", "D", "--", "OpenMP target (2 nodes)"),
    "openacc":        ("#bcbd22", "s", "-",  "OpenACC (1 node)"),
    "openacc_2node":  ("#d62728", "D", "--", "OpenACC (2 nodes)"),
}


def load(csv_path):
    df = pd.read_csv(csv_path)
    numeric = ["wall_time_s", "d_mass", "d_te", "nx", "nz", "sim_time",
               "ranks", "threads_per_rank", "total_cores", "nodes"]
    if "gpus" in df.columns:
        numeric.append("gpus")
    for c in numeric:
        df[c] = pd.to_numeric(df[c], errors="coerce")
    df["passed"] = df["passed"].astype(str).str.lower() == "true"
    if "gpus" not in df.columns:
        df["gpus"] = 0
    df["gpus"] = df["gpus"].fillna(0).astype(int)
    df["Mcells_per_sec"] = df["nx"] * df["nz"] * df["sim_time"] / df["wall_time_s"] / 1e6
    df["family"] = df["variant"].apply(lambda v: "GPU" if v in GPU_VARIANTS else "CPU")
    return df


def summarize(df):
    grp = ["variant", "family", "size", "nodes", "ranks",
           "threads_per_rank", "total_cores", "gpus"]
    agg = df.groupby(grp).agg(
        n_runs=("wall_time_s", "count"),
        wall_median=("wall_time_s", "median"),
        wall_std=("wall_time_s", "std"),
        fom_median=("Mcells_per_sec", "median"),
    ).reset_index()
    agg["rel_stddev_pct"] = (100.0 * agg["wall_std"] / agg["wall_median"]).fillna(0)
    agg.drop(columns=["wall_std"], inplace=True)
    return agg


def add_speedups(agg):
    """speedup_vs_serial: always vs serial-CPU at same size (apples-to-everything)."""
    serial = agg[agg["variant"] == "serial"].set_index("size")["wall_median"]
    agg["serial_wall"] = agg["size"].map(serial)
    agg["speedup_vs_serial"] = agg["serial_wall"] / agg["wall_median"]
    return agg


def best_per_variant(agg, size):
    """Return one row per variant, the configuration with the highest FOM."""
    sub = agg[agg["size"] == size]
    idx = sub.groupby("variant")["fom_median"].idxmax()
    return sub.loc[idx].sort_values("fom_median", ascending=True)


# =====================================================================
# Plot 1 (THE main figure):  overview.png
# =====================================================================
def plot_overview(agg, out_dir):
    """Master figure: best-in-class per family, across all sizes."""
    known_order = ["easy", "medium", "hard"]
    sizes = [s for s in known_order if s in agg["size"].values]
    if not sizes:
        return

    # Categories shown. Each tuple: (variant, label, color)
    categories = [
        ("serial",          "Serial (1 core)",        "#bbbbbb"),
        ("mpi",             "Best CPU 1-node",        "#666666"),
        ("mpi_2node",       "Best CPU 2-node",        "#222222"),
        ("openacc",         "Best GPU 1-node",        "#ff6666"),
        ("openacc_2node",   "Best GPU 2-node",        "#cc0000"),
    ]

    fig, axes = plt.subplots(1, len(sizes),
                             figsize=(5.0 * len(sizes), 4.5),
                             squeeze=False)
    axes = axes[0]

    # Find global x range so all 3 panels share the same log axis
    max_speedup = 0
    for size in sizes:
        sub = agg[agg["size"] == size]
        for variant, _, _ in categories:
            v = sub[sub["variant"] == variant]
            if not v.empty:
                max_speedup = max(max_speedup, v["speedup_vs_serial"].max())

    for ax, size in zip(axes, sizes):
        sub = agg[agg["size"] == size]
        labels, speedups, walls, colors, configs = [], [], [], [], []
        for variant, label, color in categories:
            v = sub[sub["variant"] == variant]
            if v.empty: continue
            best = v.loc[v["fom_median"].idxmax()]
            n = int(best["gpus"]) if best["family"] == "GPU" else int(best["total_cores"])
            unit = "GPU" if best["family"] == "GPU" else "core"
            pl = "s" if n > 1 else ""
            nn = int(best["nodes"])
            cfg = f"{n} {unit}{pl}" + (f" × {nn}N" if nn > 1 else "")
            labels.append(label)
            speedups.append(best["speedup_vs_serial"])
            walls.append(best["wall_median"])
            colors.append(color)
            configs.append(cfg)

        y = np.arange(len(labels))
        ax.barh(y, speedups, color=colors, edgecolor="black", linewidth=0.6)

        # Two-line tick labels: category on top, actual config below
        tick_labels = [f"{lab}\n({cfg})" for lab, cfg in zip(labels, configs)]
        ax.set_yticks(y); ax.set_yticklabels(tick_labels, fontsize=9)

        # Annotate each bar with speedup × and wall time
        for i, (sp, w) in enumerate(zip(speedups, walls)):
            ax.text(sp * 1.05, i, f"{sp:.0f}×\n{w:.2f}s",
                    va="center", fontsize=9, fontweight="bold")

        ax.set_xscale("log")
        ax.set_xlim(0.7, max_speedup * 2.5)
        ax.set_xlabel("Speedup vs serial (log)")
        ax.set_title(f"{size}  (NX×NZ from data)", fontsize=11, fontweight="bold")
        ax.grid(True, alpha=0.3, axis="x", which="both")
        ax.invert_yaxis()

    fig.suptitle("miniWeather baseline — best result per hardware family",
                 fontsize=13, fontweight="bold")
    fig.tight_layout(rect=[0, 0, 1, 0.96])
    p = out_dir / "overview.png"
    fig.savefig(p, dpi=140); plt.close(fig)
    print(f"  wrote {p}")


# =====================================================================
# Plot 2:  scaling_<size>.png
# =====================================================================
def plot_scaling(agg, size, out_dir):
    """CPU strong scaling (left) + GPU strong scaling (right). Cleaner."""
    fig, axes = plt.subplots(1, 2, figsize=(13, 5))
    sub = agg[agg["size"] == size].copy()

    # ---- CPU panel ----
    ax = axes[0]
    cpu = sub[sub["family"] == "CPU"].sort_values("total_cores")
    for variant, (color, marker, linestyle, label) in CPU_STYLES.items():
        s = cpu[cpu["variant"] == variant]
        if s.empty: continue
        ax.plot(s["total_cores"], s["speedup_vs_serial"],
                marker=marker, color=color, linestyle=linestyle,
                label=label, linewidth=2, markersize=8)
    cores = sorted(cpu["total_cores"].dropna().unique())
    if cores:
        ax.plot(cores, cores, "k:", alpha=0.5, label="ideal", linewidth=1)
    ax.set_xlabel("CPU cores")
    ax.set_ylabel("speedup vs serial")
    ax.set_title(f"CPU strong scaling — {size}")
    if cores: ax.set_xscale("log", base=2)
    ax.set_yscale("log", base=2)
    ax.legend(fontsize=9, loc="upper left")
    ax.grid(True, alpha=0.3)

    # ---- GPU panel ----
    ax = axes[1]
    gpu = sub[sub["family"] == "GPU"].sort_values("gpus")
    for variant, (color, marker, linestyle, label) in GPU_STYLES.items():
        s = gpu[gpu["variant"] == variant]
        if s.empty: continue
        ax.plot(s["gpus"], s["speedup_vs_serial"],
                marker=marker, color=color, linestyle=linestyle,
                label=label, linewidth=2, markersize=8)
    if not gpu.empty:
        ax.set_xscale("log", base=2)
    ax.set_yscale("log", base=2)
    ax.set_xlabel("GPUs")
    ax.set_ylabel("speedup vs serial-CPU")
    ax.set_title(f"GPU strong scaling — {size}")
    ax.legend(fontsize=9, loc="lower left")
    ax.grid(True, alpha=0.3)

    fig.tight_layout()
    p = out_dir / f"scaling_{size}.png"
    fig.savefig(p, dpi=140); plt.close(fig)
    print(f"  wrote {p}")


# =====================================================================
# Tables (console output only — no more cluttered FOM bars)
# =====================================================================
def print_best_summary(agg):
    """Compact table: best CPU 1N / 2N, best GPU 1N / 2N per size."""
    sizes_order = ["easy", "medium", "hard"]
    sizes = [s for s in sizes_order if s in agg["size"].values]
    if not sizes: return

    rows = []
    for size in sizes:
        sub = agg[agg["size"] == size]
        for category, filt in [
            ("CPU 1N", lambda s: s[(s["family"] == "CPU") & (s["nodes"] == 1) & (s["variant"] != "serial")]),
            ("CPU 2N", lambda s: s[(s["family"] == "CPU") & (s["nodes"] == 2)]),
            ("GPU 1N", lambda s: s[(s["family"] == "GPU") & (s["nodes"] == 1)]),
            ("GPU 2N", lambda s: s[(s["family"] == "GPU") & (s["nodes"] == 2)]),
        ]:
            fsub = filt(sub)
            if fsub.empty: continue
            best = fsub.loc[fsub["fom_median"].idxmax()]
            n = int(best["gpus"]) if best["family"] == "GPU" else int(best["total_cores"])
            unit = "GPU" if best["family"] == "GPU" else "core"
            cfg = f"{best['variant']} ({n} {unit}{'s' if n > 1 else ''})"
            rows.append({
                "size": size,
                "category": category,
                "config": cfg,
                "wall (s)": f"{best['wall_median']:.2f}",
                "Mcells/sec": f"{best['fom_median']:.2f}",
                "speedup": f"{best['speedup_vs_serial']:.1f}×",
            })

    if rows:
        print("\n========== BEST RESULT PER CATEGORY ==========")
        df = pd.DataFrame(rows)
        print(df.to_string(index=False))


def print_headlines(agg):
    sizes_order = ["easy", "medium", "hard"]
    sizes = [s for s in sizes_order if s in agg["size"].values]

    cpu_cols = ["variant", "nodes", "ranks", "threads_per_rank", "total_cores",
                "wall_median", "rel_stddev_pct", "fom_median", "speedup_vs_serial"]
    gpu_cols = ["variant", "nodes", "gpus",
                "wall_median", "rel_stddev_pct", "fom_median", "speedup_vs_serial"]

    for size in sizes:
        sub = agg[agg["size"] == size]
        cpu = sub[sub["family"] == "CPU"][cpu_cols].sort_values(["variant", "nodes", "total_cores"])
        gpu = sub[sub["family"] == "GPU"][gpu_cols].sort_values(["variant", "nodes", "gpus"])

        print(f"\n========== {size} — CPU ==========")
        if cpu.empty: print("  (no CPU data)")
        else: print(cpu.to_string(index=False, float_format=lambda x: f"{x:.3f}"))

        print(f"\n========== {size} — GPU ==========")
        if gpu.empty: print("  (no GPU data)")
        else: print(gpu.to_string(index=False, float_format=lambda x: f"{x:.3f}"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", default="results/runs.csv")
    ap.add_argument("--out", default="results/plots")
    args = ap.parse_args()

    csv_path = Path(args.csv); out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    if not csv_path.exists():
        print(f"ERROR: {csv_path} not found"); sys.exit(1)

    df = load(csv_path)
    print(f"Loaded {len(df)} runs from {csv_path}")
    n_pass = df["passed"].sum()
    print(f"  passed validation: {n_pass}/{len(df)}")
    if n_pass < len(df):
        print("\nFAILED RUNS:")
        failed = df[~df["passed"]][["variant", "size", "ranks", "threads_per_rank",
                                     "gpus", "run_id", "wall_time_s", "d_mass", "d_te"]]
        print(failed.to_string(index=False))

    df_ok = df[df["passed"]].copy()
    agg = summarize(df_ok)
    agg = add_speedups(agg)

    summary_path = out_dir.parent / "summary.csv"
    agg.to_csv(summary_path, index=False)
    print(f"\nWrote aggregated summary -> {summary_path}")

    print_headlines(agg)
    print_best_summary(agg)

    print("\n========== GENERATING PLOTS ==========")
    plot_overview(agg, out_dir)
    sizes_order = ["easy", "medium", "hard"]
    for size in [s for s in sizes_order if s in agg["size"].values]:
        plot_scaling(agg, size, out_dir)
    print(f"\nAll plots saved to {out_dir}/")


if __name__ == "__main__":
    main()
