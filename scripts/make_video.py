#!/usr/bin/env python3
"""
Convert miniWeather's output_<size>.nc into an animated video.

Run on the login node after `sbatch slurm/make_video_data.sbatch`.

Usage:
    source activate.sh

    # Default: read results/viz/output_easy.nc -> animation_easy.mp4
    python3 scripts/make_video.py

    # Pick a specific size
    python3 scripts/make_video.py --size medium
    python3 scripts/make_video.py --size hard

    # Render only one variable, higher FPS
    python3 scripts/make_video.py --size medium --var theta --fps 15

    # Custom paths
    python3 scripts/make_video.py --nc /path/to/output.nc --out /path/to/anim.mp4
"""

import argparse
import sys
from pathlib import Path

import numpy as np

# Headless backend (cluster login nodes have no DISPLAY)
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation, FFMpegWriter, PillowWriter

# Point matplotlib at imageio_ffmpeg's bundled binary
try:
    import imageio_ffmpeg
    matplotlib.rcParams["animation.ffmpeg_path"] = imageio_ffmpeg.get_ffmpeg_exe()
except Exception:
    pass

try:
    from netCDF4 import Dataset
except ImportError:
    print("ERROR: netCDF4 missing. Run: bash setup_python.sh", file=sys.stderr)
    sys.exit(1)


# (description, units, colormap)
VAR_INFO = {
    "dens":  ("Density perturbation",        "kg/m^3", "RdBu_r"),
    "uwnd":  ("Horizontal velocity (u)",     "m/s",    "RdBu_r"),
    "wwnd":  ("Vertical velocity (w)",       "m/s",    "RdBu_r"),
    "theta": ("Potential temperature pert.", "K",      "RdBu_r"),
}


def symmetric_limits(arr):
    m = np.nanmax(np.abs(arr))
    if m == 0 or not np.isfinite(m):
        return (-1.0, 1.0)
    return (-m, m)


def load_nc(nc_path):
    ds = Dataset(nc_path, "r")
    print(f"Loaded: {nc_path}")
    print(f"  variables:  {list(ds.variables.keys())}")
    print(f"  dimensions: {{ {', '.join(f'{d}={len(ds.dimensions[d])}' for d in ds.dimensions)} }}")
    t = ds.variables["t"][:]
    fields = {v: ds.variables[v][:] for v in ("dens", "uwnd", "wwnd", "theta")
              if v in ds.variables}
    if not fields:
        print("ERROR: no recognised variables in NC.", file=sys.stderr)
        sys.exit(1)
    for v, a in fields.items():
        print(f"  {v}: shape={a.shape}  range=[{a.min():.3e}, {a.max():.3e}]")
    return t, fields


def render(t, fields, out_path, fps, single_var=None, size_label=None):
    if single_var:
        if single_var not in fields:
            print(f"ERROR: variable '{single_var}' not in NC.", file=sys.stderr)
            sys.exit(1)
        plot_vars = [single_var]
    else:
        plot_vars = [v for v in ("theta", "wwnd", "dens", "uwnd") if v in fields]

    n_frames = len(t)
    print(f"Building: {len(plot_vars)} panel(s), {n_frames} frames @ {fps} fps")

    if len(plot_vars) == 1:
        fig, axes = plt.subplots(1, 1, figsize=(10, 5))
        axes = np.array([axes])
    else:
        fig, axes = plt.subplots(2, 2, figsize=(14, 7))
        axes = axes.flatten()

    images = []
    for ax, v in zip(axes, plot_vars):
        arr = fields[v]
        vmin, vmax = symmetric_limits(arr)
        long_name, units, cmap = VAR_INFO.get(v, (v, "", "RdBu_r"))
        im = ax.imshow(arr[0], origin="lower", aspect="auto",
                       cmap=cmap, vmin=vmin, vmax=vmax,
                       interpolation="bilinear")
        cb = fig.colorbar(im, ax=ax, shrink=0.85)
        cb.set_label(units, fontsize=8)
        ax.set_title(f"{v}  —  {long_name}", fontsize=10)
        ax.set_xlabel("x (cell)")
        ax.set_ylabel("z (cell)")
        images.append(im)

    for ax in axes[len(plot_vars):]:
        ax.set_visible(False)

    size_prefix = f"[{size_label}] " if size_label else ""
    suptitle = fig.suptitle("", fontsize=12)
    fig.tight_layout(rect=[0, 0, 1, 0.96])

    def update(frame):
        for im, v in zip(images, plot_vars):
            im.set_array(fields[v][frame])
        suptitle.set_text(f"{size_prefix}miniWeather — frame {frame+1}/{n_frames} — t = {t[frame]:.2f} s")
        return images + [suptitle]

    anim = FuncAnimation(fig, update, frames=n_frames,
                         interval=1000.0 / fps, blit=False)

    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    if out_path.suffix.lower() == ".mp4":
        try:
            writer = FFMpegWriter(fps=fps, bitrate=2400, codec="libx264",
                                  extra_args=["-pix_fmt", "yuv420p"])
            anim.save(out_path, writer=writer, dpi=110)
            print(f"Saved MP4: {out_path} ({out_path.stat().st_size/1024:.1f} KB)")
        except Exception as e:
            print(f"MP4 failed ({e}); falling back to GIF.")
            out_path = out_path.with_suffix(".gif")
            anim.save(out_path, writer=PillowWriter(fps=fps), dpi=90)
            print(f"Saved GIF: {out_path} ({out_path.stat().st_size/1024:.1f} KB)")
    else:
        anim.save(out_path, writer=PillowWriter(fps=fps), dpi=90)
        print(f"Saved GIF: {out_path} ({out_path.stat().st_size/1024:.1f} KB)")

    plt.close(fig)
    return out_path


def main():
    ap = argparse.ArgumentParser(description="Animate miniWeather output NetCDF")
    ap.add_argument("--size", choices=["easy", "medium", "hard"], default="easy",
                    help="Which size to animate (default: easy). "
                         "Uses results/viz/output_<size>.nc as input "
                         "and writes results/viz/animation_<size>.mp4.")
    ap.add_argument("--nc",  default=None,
                    help="Override NetCDF input path (default: results/viz/output_<size>.nc)")
    ap.add_argument("--out", default=None,
                    help="Override output path (default: results/viz/animation_<size>.mp4)")
    ap.add_argument("--var", default=None,
                    help="Render single variable only (dens|uwnd|wwnd|theta). "
                         "Default: all four in 2x2 grid.")
    ap.add_argument("--fps", type=int, default=10,
                    help="Frames per second (default: %(default)d)")
    args = ap.parse_args()

    nc_path = Path(args.nc) if args.nc else Path(f"results/viz/output_{args.size}.nc")

    if args.out:
        out_path = Path(args.out)
    else:
        suffix = f"_{args.var}" if args.var else ""
        out_path = Path(f"results/viz/animation_{args.size}{suffix}.mp4")

    if not nc_path.exists():
        print(f"ERROR: {nc_path} not found.", file=sys.stderr)
        print(f"  Run first:  VIZ_SIZE={args.size} sbatch slurm/make_video_data.sbatch", file=sys.stderr)
        # List what IS available, helpfully
        viz_dir = Path("results/viz")
        if viz_dir.exists():
            avail = sorted(viz_dir.glob("output_*.nc"))
            if avail:
                print("  Available:", file=sys.stderr)
                for f in avail:
                    print(f"    {f}", file=sys.stderr)
        sys.exit(1)

    t, fields = load_nc(nc_path)
    out_path = render(t, fields, out_path, args.fps,
                      single_var=args.var, size_label=args.size)
    print()
    print("Copy to local machine to view:")
    print(f"  scp <user>@<host>:{out_path.resolve()} ./")


if __name__ == "__main__":
    main()
