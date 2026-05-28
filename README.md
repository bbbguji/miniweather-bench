# miniWeather Baseline (Taiwania 2 / contest_v100)

CPU baselines for [miniWeather](https://github.com/mrnorman/miniWeather)
on 台灣杉二號. This repo lets the team:

1. **Establish a serial / OpenMP / MPI / hybrid baseline** across 1-node
   and 2-node configurations
2. **Validate correctness** against upstream's canonical test
3. **Visualize** the rising thermal bubble to verify the simulation
   looks physically reasonable
4. **Compare your optimized variant** (OpenMP-tuned, AVX-512, CUDA, …)
   against the baseline in a consistent way

---

## Cluster constraints (updated QOS = contest_v100)

| Resource | Limit |
|----------|-------|
| Concurrent **running** jobs | **1** |
| Max nodes per job | 2 |
| Max cores per job | 64 |
| Max GPUs per job | 16 |
| Max wall time per job | **1 hour** |

Thread / rank counts limited to {1, 2, 4, 8, 16, 32, 64}. Cross-node
runs (nodes=2) test cluster-network scaling on top of single-node
shared-memory scaling.

> **Note on Python**: cluster system Python is 3.6 (EOL). `setup_python.sh`
> uses the cluster's `miniforge` module to create a conda env with
> Python 3.11 + scientific packages. Always `source activate.sh` in a
> new shell before running `analyze.py` or `make_video.py`.

---

## Quick start

```bash
# 1. Clone into your work directory
git clone <repo-url> /work/$USER/miniWeather-bench
cd /work/$USER/miniWeather-bench

# 2. (Optional) edit SLURM account if needed
nano config.sh

# 3. One-time setup — clones miniWeather upstream, checks pnetcdf
bash setup.sh

# 4. Build PnetCDF (~10 min, one-time)
sbatch slurm/00_pnetcdf.sbatch

# 5. Build all benchmark binaries (~5 min)
sbatch slurm/01_compile.sbatch

# 6. Sanity check (~3-5 min) — do this BEFORE the full sweep
sbatch slurm/02_smoke.sbatch

# 7. Strict correctness check (~5 min) — proves implementation is bug-free
sbatch slurm/check_correctness.sbatch

# 8. Run benchmarks — choose one:

#    8a. Single benchmark (fast, for development)
sbatch slurm/bench_medium_openmp.sbatch

#    8b. Full sweep — sequential controller (3-8 hr including queue waits)
tmux new -s mw
bash submit_chain.sh
# Ctrl-b d to detach; `tmux attach -t mw` to reattach

# 9. Set up Python env (one-time, ~3 min)
bash setup_python.sh

# 10. In every new shell:
source activate.sh
python3 scripts/analyze.py        # benchmark plots + tables
```

---

# Testing methodology

## Problem sizes

Three benchmark sizes, all with **the same sim_time=20** so wall-time
scales purely with grid size:

| size | NX × NZ | sim_time | role | est. serial wall |
|------|---------|----------|------|------------------|
| **easy** | 1000×500 | 20 | fast iteration; cache-resident on 8+ cores | ~1.3 min |
| **medium** | 1600×800 | 20 | **main** benchmark | ~5.3 min |
| **hard** | 2000×1000 | 20 | bandwidth-bound stress test | ~10.3 min |

Plus one **separate** size used only for strict correctness:

| size | NX × NZ | sim_time | role |
|------|---------|----------|------|
| canonical | 200×100 | 400 | upstream's official correctness test |

## Variants tested

For each size we benchmark four parallelization strategies on 1 node
plus selected MPI / hybrid configurations on 2 nodes:

| variant | what it tests | configs |
|---------|---------------|---------|
| **serial** | reference; the speedup denominator | 1 core |
| **openmp** | shared-memory parallelism | 1, 2, 4, 8, 16, 32 threads |
| **mpi** | distributed-memory on 1 node | 1, 2, 4, 8, 16, 32 ranks |
| **mpi_2node** | distributed across 2 nodes | 32, 64 ranks |
| **hybrid** | MPI ranks + OpenMP threads, 1 node | 2R×16T, 4R×8T, 8R×4T, 16R×2T |
| **hybrid_2node** | MPI + OpenMP across 2 nodes | 8R×8T, 16R×4T, 32R×2T |

On `hard`, the 1-thread/1-rank configs are skipped (each rep takes ~10
min and a single sbatch only has 55 min).

## Run protocol

Each configuration is run **3 times**. All reps share the same sbatch
(so they share node state). Report **median + relative standard
deviation %** (`rel_stddev_pct`). With 3 reps, IQR / quartiles aren't
meaningful so we don't report them.

## Metrics

`results/runs.csv` rows (raw, one per individual run):

| column | meaning | how computed |
|--------|---------|--------------|
| `wall_time_s` | wallclock seconds for one run | from miniWeather's `CPU Time:` line |
| `d_mass` | relative mass change | `(mass_final − mass_initial) / mass_initial` |
| `d_te` | relative total-energy change | `(te_final − te_initial) / te_initial` |
| `passed` | did this run validate? | `\|d_mass\| < 1e-8 AND d_te < 1e-8 AND \|d_te\| < 1e-2` |

`results/summary.csv` rows (aggregated by `analyze.py`):

| column | formula | what it tells you |
|--------|---------|-------------------|
| `wall_median` | median of `wall_time_s` across reps | **the** wall-clock number to report |
| `rel_stddev_pct` | `100 × std(wall_time) / median(wall_time)` | run-to-run noise; should be < 1% on idle node |
| `fom_median` | `NX × NZ × sim_time / wall_median / 1e6` | **figure of merit**; throughput in Mcells/sec |
| `speedup` | `wall_serial(same size) / wall_median` | scaling vs serial reference |
| `parallel_eff` | `speedup / total_cores` | how close to ideal scaling; 1.0 is perfect |

## Two-level validation

### Level 1: Benchmark catastrophic-only validation

Applied to every row of `results/runs.csv`:

* `|d_mass| < 1e-8` — catches NaN, blowup
* `d_te ≤ 1e-8` — energy must not increase noticeably
* `|d_te| < 1e-2` — catches catastrophic blow-up

Allows mild FP error accumulation while still catching real bugs.

### Level 2: Strict upstream-spec validation

Run via `sbatch slurm/check_correctness.sbatch`. Uses upstream's
canonical test (NX=200, NZ=100, sim_time=400) with **strict**
thresholds:

* `|d_mass| < 1e-13` — relative mass change near machine epsilon
* `d_te ∈ (−4.5e-5, 0)` — energy must dissipate mildly

A new variant should pass **both**.

---

# Visualization

The benchmark binaries have `OUT_FREQ=-1` (no I/O) to avoid biasing
timing. Separate viz binaries are built on demand.

```bash
# 1. Compile + run viz binary for chosen size
sbatch slurm/make_video_data.sbatch                    # default: easy
VIZ_SIZE=medium sbatch slurm/make_video_data.sbatch    # medium
VIZ_SIZE=hard   sbatch slurm/make_video_data.sbatch    # hard (slowest)

# 2. After job finishes, on login node:
source activate.sh
python3 scripts/make_video.py --size easy
python3 scripts/make_video.py --size medium
python3 scripts/make_video.py --size hard

# 3. Copy to local machine
scp <user>@<host>:/work/<user>/miniWeather-bench/results/viz/animation_easy.mp4 ./
```

Each size writes to its own file (`output_<size>.nc`,
`animation_<size>.mp4`) so multiple can coexist.

Default output: 2×2 panel showing **theta** (potential temperature
pert.), **wwnd** (vertical wind), **dens** (density pert.), **uwnd**
(horizontal wind). With `DATA_SPEC_THERMAL` you should see a warm
bubble rising and developing a mushroom-cap plume.

Options:

```bash
# Single variable, higher FPS, GIF
python3 scripts/make_video.py --size medium --var theta --fps 15 \
    --out results/viz/theta_medium.gif

# Custom params (override preset)
VIZ_SIZE=custom VIZ_NX=1200 VIZ_NZ=600 VIZ_SIM_TIME=30 VIZ_OUT_FREQ=0.25 \
    sbatch slurm/make_video_data.sbatch
```

---

# How to add your own variant

Your variant (`openmp_tuned`, `avx512`, `cuda`, `mpi_cuda`, …) is
"successful" if its `fom_median` (Mcells/sec) beats the baseline at the
same size + total cores.

## Step 1. Implement

Build as `builds/<size>/<your_variant>` for each size. Use the same
compile flags as the baseline (see `slurm/01_compile.sbatch`) unless
your optimization requires changes — document any difference.

## Step 2. Validate correctness FIRST

Before measuring performance, run a strict check on your variant. Copy
`slurm/check_correctness.sbatch` and edit it to use your binary. Your
variant **must** produce:

* `|d_mass| < 1e-13`
* `d_te ∈ (−4.5e-5, 0)`

If not, fix the bug before benchmarking.

## Step 3. Add a runner in `scripts/run_one.sh`

```bash
run_my_variant() {
  local size=$1 cores=$2 rep=$3
  read nx nz st <<< $(get_size_params $size)
  local exe=$BASE/builds/$size/my_variant
  [ -x "$exe" ] || { echo "  [skip] missing $exe"; return; }
  echo "[my_variant / $size / ${cores}-core / rep $rep]"
  # ... your launch command (use $SRUN_MPI if it's MPI) ...
  local out=$(srun $SRUN_MPI ... "$exe" 2>&1)
  parse_and_log "$out" my_variant $size $nx $nz $st 1 $ranks $threads $cores $rep
  #                    ^^^^^^^^^^ this is the variant column name in runs.csv
}
```

**Variant naming**: reserved names are `serial`, `openmp`, `mpi`,
`hybrid`, `mpi_2node`, `hybrid_2node`. Use a unique name for yours.
`analyze.py` will auto-pick it up if you add it to `SCALING_VARIANTS`
at the top of that file (otherwise it'll appear in `summary.csv` and
`fom_*.png` but not on the scaling plot).

## Step 4. Add an sbatch file

```bash
cp slurm/bench_medium_openmp.sbatch slurm/bench_medium_my_variant.sbatch
# edit:
#   - #SBATCH --job-name=mw_m_myv
#   - #SBATCH -o logs/medium_my_variant_%j.log
#   - #SBATCH -e logs/medium_my_variant_%j.err
#   - replace run_openmp calls with run_my_variant
```

Use the same `NREPS=3` so your data is comparable.

## Step 5. Run + analyze

```bash
sbatch slurm/bench_medium_my_variant.sbatch
# ... wait ...
source activate.sh
python3 scripts/analyze.py
```

`analyze.py` automatically merges your variant's rows with the baseline
and computes its speedup vs serial of the same size.

## Step 6. Compare against baseline

In `results/summary.csv` and `results/plots/scaling_<size>.png` look at:

* **`fom_median`** is **higher** than the best baseline variant at the
  same size + cores
* The improvement is **larger than 2σ** of run-to-run noise (a 5%
  speedup is only meaningful if `rel_stddev_pct` is < 2.5%)
* Your variant **also passes the strict correctness check**

Use `baseline_reference/runs.csv` as the canonical "before" data; your
own `results/runs.csv` is the "after".

---

## File layout

```
.
├── config.sh                    # SLURM account / partition
├── setup.sh                     # one-time: clone miniWeather, check pnetcdf
├── setup_python.sh              # one-time: create conda env (Python 3.11)
├── activate.sh                  # source this in every new shell
├── submit_chain.sh              # sequential controller
├── README.md
├── slurm/
│   ├── 00_pnetcdf.sbatch        # build PnetCDF
│   ├── 01_compile.sbatch        # build all benchmark binaries
│   ├── 02_smoke.sbatch          # 1-rep sanity check
│   ├── check_correctness.sbatch # strict upstream validation
│   ├── make_video_data.sbatch   # produce output_<size>.nc for viz
│   ├── bench_<size>_<variant>.sbatch       # 12 single-node benches
│   └── bench2n_<size>_<variant>.sbatch     # 5 two-node benches
├── scripts/
│   ├── run_one.sh               # helpers sourced by sbatch
│   ├── analyze.py               # statistics + plots
│   └── make_video.py            # NC → MP4
├── baseline_reference/          # committed: Team A's reference data
│   ├── runs.csv
│   ├── correctness.csv
│   ├── summary.csv
│   └── plots/
│
├── builds/                      # gitignored — per-machine binaries
├── results/                     # gitignored — your own runs
├── logs/                        # gitignored — SLURM + raw outputs
├── external/                    # gitignored — PnetCDF install
├── miniWeather/                 # gitignored — upstream clone
└── conda_env/                   # gitignored — conda env (Python 3.11)
```

---

## Known cluster quirks (worked around)

| Quirk | Fix |
|-------|-----|
| OpenMPI 5 aborts because `OMPI_MCA_opal_cuda_support=1` set but lib lacks CUDA | `run_one.sh` disables it |
| Slurm's `MpiDefault=pmi2` causes OpenMPI 5 ranks to launch in **singleton mode** | All `srun` calls pass `--mpi=pmix`; runtime detector warns if it happens again |
| `--exclusive` not allowed | not used |
| `sbatch` stderr warnings confused chain controller | extract pure-numeric jobid via regex |
| System Python is 3.6 (EOL) | use cluster's `miniforge` module via `setup_python.sh` |

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| `QOSMaxSubmitJobPerUserLimit` | another `mw_*` job in queue: `squeue -u $USER` |
| `QOSMaxWallDurationPerJobLimit` | sbatch `--time` > 1 hour |
| smoke test all `passed=false` | `cat logs/runs/*.out` — likely MPI launch error |
| 32R timing ≈ 1R (no scaling) | MPI in singleton mode. Verify `--mpi=pmix`. Each raw log should print `nx_glob:` exactly once for any rank count |
| variance > 15% between reps | other jobs sharing your node (can't fix without `--exclusive`) |
| `ModuleNotFoundError` in Python | did you `source activate.sh`? |
| `output_<size>.nc not found` | run `VIZ_SIZE=<size> sbatch slurm/make_video_data.sbatch` first |
