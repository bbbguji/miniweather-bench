#!/usr/bin/env python3
"""
Post-process miniWeather baseline runs.

Reads results/runs.csv, computes statistics per (variant, size, config),
generates scaling plots and a summary table. Keep only the metrics that
matter for 3-rep statistics:
    wall_median, fom_median, speedup, parallel_eff, rel_stddev_pct

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


def load(csv_path):
    df = pd.read_csv(csv_path)
    for c in ["wall_time_s", "d_mass", "d_te", "nx", "nz", "sim_time",
              "ranks", "threads_per_rank", "total_cores", "nodes"]:
        df[c] = pd.to_numeric(df[c], errors="coerce")
    df["passed"] = df["passed"].astype(str).str.lower() == "true"
    df["Mcells_per_sec"] = df["nx"] * df["nz"] * df["sim_time"] / df["wall_time_s"] / 1e6
    return df


def summarize(df):
    grp = ["variant", "size", "nodes", "ranks", "threads_per_rank", "total_cores"]
    agg = df.groupby(grp).agg(
        n_runs=("wall_time_s", "count"),
        n_passed=("passed", "sum"),
        wall_median=("wall_time_s", "median"),
        wall_std=("wall_time_s", "std"),
        fom_median=("Mcells_per_sec", "median"),
    ).reset_index()
    agg["rel_stddev_pct"] = 100.0 * agg["wall_std"] / agg["wall_median"]
    agg.drop(columns=["wall_std"], inplace=True)
    return agg


def add_speedup(agg, baseline_variant="serial"):
    base = agg[agg["variant"] == baseline_variant].set_index("size")["wall_median"]
    agg["serial_wall"] = agg["size"].map(base)
    agg["speedup"] = agg["serial_wall"] / agg["wall_median"]
    agg["parallel_eff"] = agg["speedup"] / agg["total_cores"]
    return agg


# Variants we plot in scaling charts. mpi_2node / hybrid_2node show
# multi-node scaling alongside the 1-node variants.
SCALING_VARIANTS = [
    ("openmp",      "tab:blue",   "o", "OpenMP"),
    ("mpi",         "tab:orange", "s", "MPI (1-node)"),
    ("mpi_2node",   "tab:red",    "D", "MPI (2-node)"),
    ("hybrid",      "tab:green",  "^", "Hybrid (1-node)"),
    ("hybrid_2node","tab:purple", "v", "Hybrid (2-node)"),
]


def plot_scaling(agg, size, out_dir):
    fig, axes = plt.subplots(1, 2, figsize=(13, 5))

    sub = agg[agg["size"] == size].copy()
    sub = sub.dropna(subset=["speedup"]).sort_values("total_cores")

    for variant, color, marker, label in SCALING_VARIANTS:
        s = sub[sub["variant"] == variant]
        if s.empty: continue
        axes[0].plot(s["total_cores"], s["speedup"], marker=marker, color=color,
                     label=label, linewidth=2, markersize=9)
        axes[1].plot(s["total_cores"], s["parallel_eff"], marker=marker, color=color,
                     label=label, linewidth=2, markersize=9)

    cores = sorted(sub["total_cores"].dropna().unique())
    if cores:
        axes[0].plot(cores, cores, "k--", alpha=0.4, label="ideal")
    axes[1].axhline(1.0, color="k", linestyle="--", alpha=0.4, label="ideal")

    axes[0].set_xlabel("total cores"); axes[0].set_ylabel(f"speedup vs serial-{size}")
    axes[0].set_title(f"Strong scaling ({size})")
    axes[0].set_xscale("log", base=2); axes[0].set_yscale("log", base=2)
    axes[0].legend(fontsize=8); axes[0].grid(True, alpha=0.3)

    axes[1].set_xlabel("total cores"); axes[1].set_ylabel("parallel efficiency")
    axes[1].set_title(f"Parallel efficiency ({size})")
    axes[1].set_xscale("log", base=2); axes[1].set_ylim(0, 1.2)
    axes[1].legend(fontsize=8); axes[1].grid(True, alpha=0.3)

    fig.tight_layout()
    p = out_dir / f"scaling_{size}.png"
    fig.savefig(p, dpi=130); plt.close(fig)
    print(f"  wrote {p}")


def plot_fom_bars(agg, size, out_dir):
    sub = agg[agg["size"] == size].copy().sort_values("fom_median", ascending=True)
    if sub.empty: return
    labels = (sub["variant"] + " " + sub["nodes"].astype(int).astype(str) + "N "
              + sub["ranks"].astype(int).astype(str) + "R"
              + "x" + sub["threads_per_rank"].astype(int).astype(str) + "T")
    fig, ax = plt.subplots(figsize=(11, max(4, 0.30 * len(sub))))
    bars = ax.barh(labels, sub["fom_median"])
    for bar, v in zip(bars, sub["fom_median"]):
        ax.text(v, bar.get_y() + bar.get_height()/2, f" {v:.1f}",
                va="center", fontsize=7)
    ax.set_xlabel("FOM: Mcells / wall-second (higher = better)")
    ax.set_title(f"Throughput by variant ({size})")
    ax.grid(True, alpha=0.3, axis="x")
    fig.tight_layout()
    p = out_dir / f"fom_{size}.png"
    fig.savefig(p, dpi=130); plt.close(fig)
    print(f"  wrote {p}")


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
                                     "run_id", "wall_time_s", "d_mass", "d_te"]]
        print(failed.to_string(index=False))

    df_ok = df[df["passed"]].copy()
    agg = summarize(df_ok)
    agg = add_speedup(agg)

    summary_path = out_dir.parent / "summary.csv"
    agg.to_csv(summary_path, index=False)
    print(f"\nWrote aggregated summary -> {summary_path}")

    head_cols = ["variant", "nodes", "ranks", "threads_per_rank", "total_cores",
                 "wall_median", "rel_stddev_pct", "fom_median", "speedup", "parallel_eff"]
    known_order = ["easy", "medium", "hard"]
    sizes = list(agg["size"].dropna().unique())
    sizes.sort(key=lambda s: known_order.index(s) if s in known_order else 99)

    for size in sizes:
        print(f"\n========== HEADLINE NUMBERS ({size}) ==========")
        rows = agg[agg["size"] == size][head_cols].sort_values(["variant", "nodes", "total_cores"])
        if rows.empty:
            print("  (no data)"); continue
        print(rows.to_string(index=False, float_format=lambda x: f"{x:.3f}"))

    print("\n========== GENERATING PLOTS ==========")
    for size in sizes:
        plot_scaling(agg, size, out_dir)
        plot_fom_bars(agg, size, out_dir)
    print(f"\nAll plots saved to {out_dir}/")


if __name__ == "__main__":
    main()
