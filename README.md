# miniWeather Baseline (Taiwania 2 / contest_v100)

CPU and GPU baselines for the [miniWeather](https://github.com/mrnorman/miniWeather)
mini-app on 台灣杉二號. This repo lets the team:

1. Establish a **5-variant baseline** (serial, MPI, MPI+OpenMP, MPI+OpenMP-target, MPI+OpenACC)
2. Validate correctness against upstream's strict thresholds
3. **Visualize** the rising thermal bubble to sanity-check the simulation
4. **Compare an optimized variant** (CUDA, AVX-512, …) against the baseline

**Headline numbers** (median of 3 reps, all 279 runs passed):

| size | best CPU 1-node | best CPU 2-node | best GPU 1-node | best GPU 2-node |
|------|----------------|-----------------|-----------------|------------------|
| easy (1000×500) | mpi 32R: 2.68s (29×) | mpi 64R: 1.43s (53×) | **openacc 1 GPU: 0.37s (207×)** | — |
| medium (1600×800) | mpi 32R: 11.27s (28×) | mpi 64R: 5.58s (57×) | openacc 1 GPU: 1.41s (226×) | **openacc 8 GPU: 1.41s (226×)** |
| hard (2000×1000) | mpi 32R: 22.50s (28×) | mpi 64R: 11.23s (56×) | openacc 1 GPU: 2.69s (232×) | **openacc 8 GPU: 2.26s (276×)** |

Targets for optimized variants to beat (hard size, sim_time=20):
- **CPU optimization**: beat `mpi_2node 64R` at **11.23s**
- **GPU optimization**: beat `openacc_2node 8 GPU` at **2.26s**

See [`baseline_reference/`](baseline_reference/) for the frozen `runs.csv`, `summary.csv`, plots, and the report-ready `overview.png`.

---

## Cluster constraints (QOS = contest_v100)

| Resource | Limit | Note |
|----------|-------|------|
| Concurrent **running** jobs | **1** (per user); group-wide also constrained | `QOSGrpJobsLimit` can leave you pending for hours |
| Max nodes per job | 2 | |
| Max cores per job | 64 | |
| Max GPUs per job | 16 | |
| **Implicit: 4 CPUs per GPU** | enforced by partition | so 32 CPU/node ⇒ must reserve 8 GPU/node |
| Max wall time per job | 1 hour | |

---

## Quick start

```bash
# 1. Clone
git clone <repo-url> /work/$USER/miniWeather-bench
cd /work/$USER/miniWeather-bench

# 2. One-time setup (clones miniWeather upstream, checks pnetcdf)
bash setup.sh
bash setup_python.sh          # conda env for analyze.py / make_video.py

# 3. Build PnetCDF (~10 min, one-time)
sbatch slurm/00_pnetcdf.sbatch

# 4. Build all 5 variants × 4 sizes (~15-30 min)
sbatch slurm/01_compile.sbatch

# 5. Sanity check (~5 min) — before the full sweep
sbatch slurm/02_smoke.sbatch

# 6. Strict correctness check (~5 min)
sbatch slurm/check_correctness.sbatch

# 7. Run the full sweep (auto-resumes if you re-run)
tmux new -s mw
bash submit_chain.sh
# Ctrl-b d to detach; `tmux attach -t mw` to reattach

# 8. Analyze (anytime, even mid-sweep)
source activate.sh
python3 scripts/analyze.py
```

## Run a single benchmark (fast iteration)

Instead of the full chain, run any individual sbatch file directly. The naming pattern is `bench[2n]_<size>_<variant>.sbatch`:

```bash
# Pattern: 1-node CPU benches
sbatch slurm/bench_easy_serial.sbatch       # serial only
sbatch slurm/bench_easy_openmp.sbatch       # OpenMP sweep (1..32 threads)
sbatch slurm/bench_easy_mpi.sbatch          # MPI sweep (1..32 ranks)
sbatch slurm/bench_easy_hybrid.sbatch       # MPI+OpenMP hybrid

# Pattern: 1-node GPU benches
sbatch slurm/bench_medium_openacc.sbatch    # OpenACC (1, 2, 4, 8 GPUs)
sbatch slurm/bench_medium_openmp45.sbatch   # OpenMP target offload

# Pattern: 2-node benches (cross-node scaling)
sbatch slurm/bench2n_hard_mpi.sbatch        # MPI on 64 cores × 2 nodes
sbatch slurm/bench2n_hard_openacc.sbatch    # OpenACC on 16 GPUs × 2 nodes
```

Every result appends to `results/runs.csv`, so you can keep accumulating data and re-run `python3 scripts/analyze.py` anytime to refresh plots and tables.

### Match the file name to what you want

| if you want to test… | use this file |
|---------------------|---------------|
| just serial baseline at small size | `bench_easy_serial.sbatch` |
| MPI scaling 1→32 ranks at medium | `bench_medium_mpi.sbatch` |
| OpenMP threads 1→32 at hard | `bench_hard_openmp.sbatch` |
| MPI+OpenMP hybrid configurations | `bench_<size>_hybrid.sbatch` |
| Cross-node MPI scaling | `bench2n_<size>_mpi.sbatch` |
| Single-GPU vs multi-GPU offload | `bench_<size>_openacc.sbatch` or `bench_<size>_openmp45.sbatch` |
| Multi-GPU across 2 nodes | `bench2n_<size>_openacc.sbatch` or `bench2n_<size>_openmp45.sbatch` |

Sizes: `easy` / `medium` / `hard`.
Variants: `serial` / `mpi` / `openmp` / `hybrid` / `openacc` / `openmp45`.

### Tune the rep count

Every bench file uses `NREPS=${NREPS:-3}`, so you can override for a quick check or a longer measurement:

```bash
NREPS=1 sbatch slurm/bench_easy_mpi.sbatch        # 1 rep — fast smoke
NREPS=5 sbatch slurm/bench_hard_openacc.sbatch    # 5 reps — tighter stats
```

### After a single run

```bash
# Watch progress
squeue -u $USER
tail -f logs/<size>_<variant>_<jobid>.log

# When done, refresh analysis
source activate.sh
python3 scripts/analyze.py
```

`analyze.py` reads everything currently in `results/runs.csv`, so partial sweeps work — the plots just show whichever (size, variant) combinations have data so far.

### Remove a bad run

If a configuration produced bogus numbers (e.g. an external interruption), you can either:

```bash
# Option A: remove all failed rows (passed=false)
bash clean_runs_csv.sh

# Option B: delete the whole CSV and re-run from scratch
mv results/runs.csv results/runs.csv.bak
# then sbatch whichever benches you want
```

---

# What gets tested

## 5 source variants

The upstream miniWeather/c repository ships 5 source files. Each compiles to a distinct binary:

| variant | source file | acceleration | uses GPU? | compiled with |
|---------|------------|--------------|-----------|---------------|
| `serial` | `miniWeather_serial.cpp` | single thread | ✗ | gcc10 + OpenMPI 5 |
| `mpi` | `miniWeather_mpi.cpp` | pure MPI | ✗ | gcc10 + OpenMPI 5 |
| `openmp` | `miniWeather_mpi_openmp.cpp` | MPI + OpenMP (CPU threads) | ✗ | gcc10 + OpenMPI 5 |
| `openmp45` | `miniWeather_mpi_openmp45.cpp` | MPI + **OpenMP 4.5 target offload** | **✓** | nvhpc 24.11 + bundled HPCX OpenMPI |
| `openacc` | `miniWeather_mpi_openacc.cpp` | MPI + **OpenACC** | **✓** | nvhpc 24.11 + bundled HPCX OpenMPI |

CPU and GPU binaries live in **separate build directories** (`builds/<size>/` and `builds/<size>_gpu/`) because the two toolchains can't share a single OpenMPI.

## 4 problem sizes

| size | NX × NZ | sim_time | role | est. serial wall |
|------|---------|----------|------|------------------|
| easy | 1000 × 500 | 20 | fast iteration; smoke test | ~76s |
| medium | 1600 × 800 | 20 | main benchmark | ~318s |
| hard | 2000 × 1000 | 20 | bandwidth stress | ~623s |
| canonical | 200 × 100 | 400 | **only** for upstream strict correctness check | — |

All three benchmark sizes share `sim_time=20` so wall-time differences come purely from grid size.

## Per-variant config sweep

For each (variant × size), we sweep parallel configurations:

| variant | configurations |
|---------|----------------|
| serial | 1 core (reference only) |
| mpi (1 node) | 1, 2, 4, 8, 16, 32 ranks |
| mpi_2node (2 nodes) | 32, 64 ranks |
| openmp (1 node) | 1, 2, 4, 8, 16, 32 threads |
| hybrid (1 node) | 2R×16T, 4R×8T, 8R×4T, 16R×2T |
| hybrid_2node (2 nodes) | 8R×8T, 16R×4T, 32R×2T |
| openmp45 (1 node) | 1, 2, 4, 8 GPUs (1 rank/GPU) |
| openmp45_2node (2 nodes) | 8, 16 GPUs |
| openacc (1 node) | 1, 2, 4, 8 GPUs |
| openacc_2node (2 nodes) | 8, 16 GPUs |

Each configuration runs **3 reps**. Total ≈ 279 benchmark runs across all sizes.

For hard size, the 1-rank/1-thread configurations of mpi/openmp are skipped to fit the 55-minute sbatch budget (each rep would take ~10 min).

## Validation

Every benchmark run goes through **catastrophic validation**: `|d_mass| < 1e-8` AND `d_te < 1e-8` AND `|d_te| < 1e-2`. Rows with `passed=true` are kept; failures are flagged in analyze.py output.

A separate `slurm/check_correctness.sbatch` runs the canonical size (NX=200, NZ=100, sim_time=400) and applies upstream's **strict** thresholds (`|d_mass| < 1e-13`, `d_te ∈ (−4.5e-5, 0)`). All baseline variants must pass both.

---

# How to read `results/summary.csv`

This file is generated by `analyze.py` from the raw `results/runs.csv`. One row per **unique configuration** (variant × size × nodes × ranks × threads × gpus), aggregated across reps:

| column | meaning |
|--------|---------|
| `variant` | one of: serial / mpi / mpi_2node / openmp / hybrid / hybrid_2node / openmp45 / openmp45_2node / openacc / openacc_2node |
| `family` | "CPU" or "GPU" |
| `size` | easy / medium / hard / canonical |
| `nodes` | 1 or 2 |
| `ranks` | total MPI ranks |
| `threads_per_rank` | OpenMP threads per rank |
| `total_cores` | ranks × threads (CPU resource used) |
| `gpus` | total GPUs used (0 for CPU variants) |
| `n_runs` | reps in this aggregation (should be 3) |
| **`wall_median`** | **median wall-clock seconds** — the primary timing |
| `rel_stddev_pct` | run-to-run variance as % of median (should be < 2%; > 5% means noisy neighbour) |
| **`fom_median`** | **NX × NZ × sim_time / wall_median / 1e6** — throughput in Mcells/sec (higher = better) |
| `serial_wall` | wall_median of `serial` at the same size (auxiliary) |
| **`speedup_vs_serial`** | `serial_wall / wall_median` — apples-to-everything comparison |

### What to look at first

1. **Sort by `(size, fom_median)`** to see the throughput hierarchy.
2. **Check `rel_stddev_pct`** — anything > 2% suggests cluster contention.
3. **`speedup_vs_serial`** is the headline number to quote.

### Filter examples

```bash
# Top 5 fastest configs at hard size
awk -F, 'NR==1 || $3=="hard"' results/summary.csv | sort -t, -k14,14gr | head -6

# Just CPU variants at medium size
awk -F, 'NR==1 || ($3=="medium" && $2=="CPU")' results/summary.csv
```

Or use pandas:

```python
import pandas as pd
df = pd.read_csv("results/summary.csv")
print(df[(df['size'] == 'hard') & (df['family'] == 'GPU')]
        .sort_values('fom_median', ascending=False)
        [['variant', 'gpus', 'nodes', 'wall_median', 'fom_median', 'speedup_vs_serial']])
```

---

# Generated plots (in `results/plots/`)

| file | what it shows |
|------|---------------|
| **`overview.png`** | **Main report figure** — 3 panels (one per size), each with 4-5 bars showing best result per hardware family (Serial → CPU 1-node → CPU 2-node → GPU 1-node → GPU 2-node) with speedup × and wall-time annotations |
| `scaling_easy.png` | Strong scaling at easy: CPU panel + GPU panel, log-log |
| `scaling_medium.png` | same, medium size |
| `scaling_hard.png` | same, hard size |

The console output (`analyze.py`) also prints full per-config tables and a "best per category" summary you can copy-paste into the report.

---

# Visualization

The benchmark binaries have `OUT_FREQ=-1` (no I/O) to avoid timing distortion. A separate viz binary with NetCDF output is built on demand:

```bash
# 1. Compile + run viz binary at chosen size
sbatch slurm/make_video_data.sbatch                    # default: easy
VIZ_SIZE=medium sbatch slurm/make_video_data.sbatch
VIZ_SIZE=hard   sbatch slurm/make_video_data.sbatch    # slowest

# 2. Render mp4 on login node
source activate.sh
python3 scripts/make_video.py --size easy
python3 scripts/make_video.py --size medium --var theta --fps 15

# 3. Copy off-cluster
scp <user>@<host>:/work/<user>/miniWeather-bench/results/viz/animation_easy.mp4 ./
```

Outputs: `results/viz/output_<size>.nc` and `results/viz/animation_<size>.mp4`. With `DATA_SPEC_THERMAL`, a warm bubble rises and develops a mushroom-cap plume.

---

# How to add your own variant

Your variant (`openmp_tuned`, `avx512`, `cuda`, `mpi_cuda`, …) is "successful" if its `fom_median` beats the baseline at the same size + total cores/GPUs.

1. **Implement**: build as `builds/<size>/<your_variant>` (CPU) or `builds/<size>_gpu/<your_variant>` (GPU)
2. **Validate first**: copy `slurm/check_correctness.sbatch`, point at your binary, must pass `|d_mass| < 1e-13` and `d_te ∈ (−4.5e-5, 0)`
3. **Add a runner** in `scripts/run_one.sh` mirroring `run_mpi` or `_run_gpu`
4. **Add an sbatch**: copy the most similar existing `bench_*.sbatch`, change variant name + job name
5. **Run and analyze**: `sbatch slurm/bench_medium_my_variant.sbatch` then `python3 scripts/analyze.py`. `analyze.py` auto-picks up new variants in `summary.csv` and the per-size headline tables; add an entry to `CPU_STYLES` or `GPU_STYLES` in `analyze.py` to appear in `scaling_*.png` too
6. **Compare against baseline**: your `fom_median` should be higher than the corresponding row in `baseline_reference/summary.csv`; the gain should exceed 2 × `rel_stddev_pct` (i.e., real, not noise); your variant must also pass strict correctness

Reserved variant names (do not reuse): `serial`, `mpi`, `mpi_2node`, `openmp`, `hybrid`, `hybrid_2node`, `openmp45`, `openmp45_2node`, `openacc`, `openacc_2node`.

---

# File layout

```
.
├── config.sh                    # SLURM account / partition
├── setup.sh                     # clone miniWeather upstream, check pnetcdf
├── setup_python.sh              # create conda env (Python 3.11)
├── activate.sh                  # source in every new shell
├── submit_chain.sh              # auto-resume sequential controller
├── bootstrap_completed.sh       # mark already-done steps after a manual run
├── clean_runs_csv.sh            # remove passed=false rows
├── fix_awk_indices.sh           # one-shot patch for old scripts after schema change
├── README.md
├── slurm/
│   ├── 00_pnetcdf.sbatch        # build PnetCDF (one-time)
│   ├── 01_compile.sbatch        # build all binaries (CPU + GPU)
│   ├── 02_smoke.sbatch          # 1-rep sanity check (uses smoke.csv)
│   ├── check_correctness.sbatch # canonical-size strict validation
│   ├── make_video_data.sbatch   # produce output_<size>.nc for viz
│   ├── bench_<size>_<variant>.sbatch       # 1-node CPU/GPU benches
│   └── bench2n_<size>_<variant>.sbatch     # 2-node CPU/GPU benches
├── scripts/
│   ├── run_one.sh               # variant runner helpers
│   ├── analyze.py               # stats + plots
│   └── make_video.py            # NetCDF → MP4
├── baseline_reference/          # COMMITTED: Team A's frozen baseline
│   ├── runs.csv
│   ├── summary.csv
│   ├── correctness.csv
│   └── plots/                   # overview.png + scaling_*.png
│
├── builds/                      # (gitignored) per-machine binaries
├── results/                     # (gitignored) your own runs
├── logs/                        # (gitignored) SLURM + raw outputs
├── external/                    # (gitignored) PnetCDF install
├── miniWeather/                 # (gitignored) upstream clone
└── conda_env/                   # (gitignored) Python 3.11 env
```

---

# Known cluster quirks (worked around in scripts)

| Quirk | Fix |
|-------|-----|
| OpenMPI 5 aborts because `OMPI_MCA_opal_cuda_support=1` set but lib lacks CUDA | `run_one.sh` exports `=0` |
| Slurm's `MpiDefault=pmi2` puts OpenMPI 5 in **singleton mode** (each rank thinks rank=0) | all `srun` use `--mpi=pmix`; runtime detector in `parse_and_log` warns if singleton-mode regresses |
| `--exclusive` rejected on this QOS | not used |
| Implicit "4 CPUs per GPU" rule | sbatch files request `--gpus-per-node` proportional to CPU need |
| `sbatch` stderr warnings confused job-id parser | extract pure-numeric job-id via regex |
| `QOSGrpJobsLimit` (group-wide, not just per-user) | `submit_chain.sh` cancels after 30 min pending and retries on next invocation |
| System Python is 3.6 (EOL) | `setup_python.sh` uses the `miniforge` module to create a Python 3.11 conda env |
| `runs.csv` schema gained a `gpus` column | `fix_awk_indices.sh` shifts old `$15` → `$16` in derivative scripts |

---

# Troubleshooting

| Symptom | Check |
|---------|-------|
| `QOSMaxSubmitJobPerUserLimit` | `squeue -u $USER` — another mw_* job already in queue |
| `QOSGrpJobsLimit` pending for hours | group-wide limit; `submit_chain.sh` will auto-cancel after 30 min and retry next pass |
| smoke test shows all `passed=false` | likely MPI launch error; check `logs/runs/*.out` |
| Multi-rank MPI gives same wall time as 1 rank | singleton mode! Verify `srun --mpi=pmix` and that `nx_glob:` appears only once per raw log |
| `rel_stddev_pct > 5%` | noisy neighbour on the node; rerun |
| `ModuleNotFoundError` in Python | forgot `source activate.sh` |
| GPU binary missing | check `builds/<size>_gpu/make.log` — most often nvhpc + PnetCDF link issue |
| `output_<size>.nc not found` | run `VIZ_SIZE=<size> sbatch slurm/make_video_data.sbatch` first |
