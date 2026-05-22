# miniWeather Baseline (Taiwania 2 / contest_v100)

CPU baselines for [miniWeather](https://github.com/mrnorman/miniWeather)
on 台灣杉二號. This repo lets the team:

1. **Establish a serial / OpenMP / MPI / hybrid baseline** on the cluster
2. **Validate correctness** against upstream's canonical test
3. **Visualize** the rising thermal bubble to verify the simulation
   looks physically reasonable
4. **Compare your optimized variant** (OpenMP-tuned, AVX-512, CUDA, …)
   against the baseline in a consistent way

---

## Baseline reference numbers (Team A's measurements)

Measured on `contest_v100` QOS (1 node, 8 cores). Median of 5 reps, all
runs `passed=true`. Raw data: `baseline_reference/`.

### Speedup (8 cores vs serial)

| size | NX×NZ | serial (s) | best 8-core (s) | speedup | who wins @ 8 cores |
|------|-------|-----------|-----------------|---------|--------------------|
| easy | 400×200 | 4.70 | 0.658 | **7.13×** | mpi 8R (89% eff) |
| medium | 800×400 | 38.68 | 5.19 | **7.45×** | mpi 8R (93% eff) |
| hard | 1600×800 | 192.6 | 25.55 | **7.54×** | mpi 8R (94% eff) |

### Strict correctness check (upstream canonical: NX=200, NZ=100, sim_time=400)

All 4 baseline variants pass upstream's strict thresholds
(`|d_mass| < 1e-13`, `d_te ∈ (-4.5e-5, 0)`):

| variant | d_mass | d_te |
|---------|--------|------|
| serial | -7.4e-15 | -3.978e-05 |
| openmp 8T | -1.2e-14 | -3.978e-05 |
| mpi 8R | -1.2e-15 | -3.978e-05 |
| hybrid 2R×4T | -7.8e-16 | -3.978e-05 |

All four produce **algebraically equivalent** answers (d_te identical to
4 significant figures).

---

## Cluster constraints (QOS = contest_v100)

| Resource | Limit |
|----------|-------|
| Wall time per job | 30 min |
| Concurrent jobs in queue | **1** |
| CPUs per job | 8 |
| GPUs per job | 2 |
| Nodes per job | 1 |

All sbatch files honor these. Thread / rank counts limited to {1, 2, 4, 8}.

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

# 4. Build PnetCDF if needed (~10 min)
sbatch slurm/00_pnetcdf.sbatch

# 5. Build all benchmark binaries (~5 min)
sbatch slurm/01_compile.sbatch

# 6. Sanity check (~3 min) — do this BEFORE the full sweep
sbatch slurm/02_smoke.sbatch

# 7. Strict correctness check (~5 min) — proves implementation is bug-free
sbatch slurm/check_correctness.sbatch

# 8. Run benchmarks — choose one workflow:

#    8a. Single benchmark (fast, for development)
sbatch slurm/bench_medium_openmp.sbatch

#    8b. Full sweep — sequential controller (2-4 hr depending on queue)
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

This section explains exactly **how** we measure performance, so anyone
who writes a new variant can compare results apples-to-apples.

## Problem sizes

Three benchmark sizes (compile-time constants baked into separate binaries):

| label | NX × NZ | sim_time | role |
|-------|---------|----------|------|
| **easy** | 400×200 | 20 | smoke test / fast iteration; fits in L3 cache |
| **medium** | 800×400 | 20 | **main** benchmark; near cache boundary |
| **hard** | 1600×800 | 12 | memory-bandwidth stress; fully out of cache |

Plus one for strict correctness (matches upstream canonical test):

| label | NX × NZ | sim_time | role |
|-------|---------|----------|------|
| canonical | 200×100 | 400 | validate algorithm vs upstream reference |

## Variants tested

For each size we benchmark four parallelization strategies:

| variant | what it tests |
|---------|---------------|
| **serial** | single-thread reference; the speedup denominator |
| **openmp** | shared-memory parallelism; 1, 2, 4, 8 threads |
| **mpi** | distributed-memory parallelism; 1, 2, 4, 8 ranks |
| **hybrid** | mixed: 2R×4T and 4R×2T (8 total cores) |

## Run protocol

Each configuration is run **5 times** (3 for `bench_hard_serial` due to
the 25-min sbatch budget). All reps are batched inside one sbatch (so
they share node/state). We report **median + IQR**, never mean.

## Metrics

Each row in `results/runs.csv` records:

| metric | meaning | how computed |
|--------|---------|--------------|
| `wall_time_s` | wallclock seconds for one run | `CPU Time:` line from miniWeather |
| `d_mass` | relative mass change | `(mass_final − mass_initial) / mass_initial` |
| `d_te` | relative total-energy change | `(te_final − te_initial) / te_initial` |
| `passed` | did this run validate? | `\|d_mass\| < 1e-8 AND d_te < 1e-8 AND \|d_te\| < 1e-2` |

`analyze.py` then aggregates these into derived metrics:

| derived metric | formula | what it tells you |
|---------------|---------|-------------------|
| **Mcells_per_sec** (FOM) | `nx × nz × sim_time / wall_time_s / 1e6` | throughput; higher is better |
| **speedup** | `wall_serial(same size) / wall_this_run` | scaling vs serial reference |
| **parallel_eff** | `speedup / total_cores` | how close to "ideal scaling"; 1.0 is perfect |
| **rel_stddev_pct** | `100 × std(wall_time) / median(wall_time)` | run-to-run noise; should be < 1% on idle node |
| `wall_iqr` | `q75(wall_time) − q25(wall_time)` | robust spread measure |

## Two-level validation

This repo runs **two distinct correctness checks**:

### Level 1: Benchmark catastrophic-only validation

Applied to every row of `results/runs.csv`. Thresholds are generous:

* `|d_mass| < 1e-8` — catches NaN, blowup, totally broken algorithms
* `d_te ≤ 1e-8` — energy must not increase noticeably (would imply bug)
* `|d_te| < 1e-2` — catches catastrophic blow-up

These allow some FP error accumulation from the larger problem sizes
while still catching real bugs.

### Level 2: Strict upstream-spec validation

Run via `sbatch slurm/check_correctness.sbatch`. Uses upstream's exact
canonical test (NX=200, NZ=100, sim_time=400) and applies upstream's
**strict** thresholds (from miniWeather's `docs/INSTALL.md`):

* `|d_mass| < 1e-13` — relative mass change must be near machine epsilon
* `d_te ∈ (−4.5e-5, 0)` — energy must dissipate but only mildly

A new variant should pass **both** levels. Catastrophic-only validates
that the benchmark didn't blow up; the strict check validates that
the algorithm is genuinely equivalent to upstream's reference.

---

# Visualization (verify simulation looks right)

The benchmark binaries have `OUT_FREQ=-1` (no I/O) to avoid biasing
timing measurements. Separate "viz" binaries with NetCDF output are
built on demand.

## Generate a video

```bash
# 1. Compile + run a viz binary for the size you want
sbatch slurm/make_video_data.sbatch                    # default: easy
VIZ_SIZE=medium sbatch slurm/make_video_data.sbatch    # medium
VIZ_SIZE=hard   sbatch slurm/make_video_data.sbatch    # hard (slowest)

# 2. After job finishes, on login node:
source activate.sh
python3 scripts/make_video.py --size easy     # default
python3 scripts/make_video.py --size medium
python3 scripts/make_video.py --size hard

# 3. Copy to local machine to play
scp <user>@<host>:/work/<user>/miniWeather-bench/results/viz/animation_easy.mp4 ./
```

Each size writes to its own file:

* NC data:   `results/viz/output_<size>.nc`
* MP4 video: `results/viz/animation_<size>.mp4`

So you can keep multiple sizes side by side without overwriting.

## Output

Default: 2×2 panel showing **theta** (potential temperature pert.),
**wwnd** (vertical wind), **dens** (density pert.), and **uwnd**
(horizontal wind), evolving across all timesteps. With
`DATA_SPEC_THERMAL` you should see a warm bubble rising and developing
a mushroom-cap plume.

## Options

```bash
# Single variable only, higher FPS, GIF instead of MP4
python3 scripts/make_video.py --size medium --var theta --fps 15 \
    --out results/viz/theta_medium.gif

# Custom physics parameters (override the size preset)
VIZ_SIZE=custom VIZ_NX=1200 VIZ_NZ=600 VIZ_SIM_TIME=30 VIZ_OUT_FREQ=0.25 \
    sbatch slurm/make_video_data.sbatch
```

---

# How to add your own variant

You're writing an optimized version (`openmp_tuned`, `avx512`, `cuda`,
`mpi_cuda`, …). Your variant is "successful" if its `Mcells_per_sec`
beats the corresponding baseline at the same size + total cores.

## Step 1. Implement your variant

Build it as `builds/<size>/<your_variant>` for each size you support.
Use the same compile flags as the baseline (see `slurm/01_compile.sbatch`)
unless your optimization requires changes. Document any difference.

## Step 2. Validate correctness FIRST

Before you measure performance, run the strict check on your variant:

```bash
# Modify check_correctness.sbatch (or copy it):
#   - have it run YOUR binary instead of the baseline binaries
#   - keep NX=200 NZ=100 SIM_TIME=400 (the canonical numbers)
sbatch slurm/check_correctness_yourvariant.sbatch
```

Your variant **must** produce:
* `|d_mass| < 1e-13`
* `d_te ∈ (−4.5e-5, 0)`

If not, you have a bug; don't proceed to benchmarks until it's fixed.

## Step 3. Add a runner in `scripts/run_one.sh`

```bash
run_my_variant() {
  local size=$1 cores=$2 rep=$3
  read nx nz st <<< $(get_size_params $size)
  local exe=$BASE/builds/$size/my_variant
  [ -x "$exe" ] || { echo "  [skip] missing $exe"; return; }
  echo "[my_variant / $size / ${cores}-core / rep $rep]"
  # ... your launch command ...
  local out=$(srun ... "$exe" 2>&1)
  parse_and_log "$out" my_variant $size $nx $nz $st 1 ranks threads cores $rep
  #              ^---- the variant column in runs.csv
}
```

**Variant naming**: reserved names are `serial`, `openmp`, `mpi`,
`hybrid`. Use a unique name for yours (e.g. `openmp_tuned`, `cuda`,
`avx512`). `analyze.py` will auto-pick it up.

## Step 4. Add an sbatch file

Copy the most relevant existing bench file:

```bash
cp slurm/bench_medium_openmp.sbatch slurm/bench_medium_my_variant.sbatch
# edit:
#   - #SBATCH --job-name=mw_m_myv
#   - #SBATCH -o logs/medium_my_variant_%j.log
#   - #SBATCH -e logs/medium_my_variant_%j.err
#   - replace `run_openmp` calls with `run_my_variant`
```

Use the same `NREPS=5` so your data is comparable.

## Step 5. Run + analyze

```bash
sbatch slurm/bench_medium_my_variant.sbatch
# ... wait for completion ...
source activate.sh
python3 scripts/analyze.py
```

`analyze.py` automatically:
* aggregates your variant's rows with the baseline rows
* computes its speedup vs serial of the same size
* puts it on the scaling plots next to baseline variants

## Step 6. Compare against the baseline

Look at `results/summary.csv` and `results/plots/scaling_<size>.png`.
You're meaningfully faster if:

* `Mcells_per_sec` (FOM) is **higher** than the best baseline variant at
  the same size + cores
* The improvement is **larger than 2σ** of run-to-run noise (a 5%
  speedup is only meaningful if your `rel_stddev_pct` is < 2.5%)
* Your variant **also passes the strict correctness check** — speed
  without correctness is a bug, not an optimization

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
│   └── bench_<size>_<variant>.sbatch
│        # size    ∈ {easy, medium, hard}
│        # variant ∈ {serial, openmp, mpi, hybrid}
│        # 12 standalone benchmark files
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

## Known cluster quirks (already worked around)

| Quirk | Fix |
|-------|-----|
| OpenMPI 5 aborts because `OMPI_MCA_opal_cuda_support=1` is set but lib lacks CUDA | `run_one.sh` disables it |
| Slurm's `MpiDefault=pmi2` causes OpenMPI 5 ranks to launch in **singleton mode** (each rank thinks it's rank 0 — no real decomposition) | All `srun` calls pass `--mpi=pmix`. There's also a runtime detector in `parse_and_log` that warns if it happens again. |
| `--exclusive` not allowed | not used |
| QOS caps CPUs at 8 | thread/rank counts capped at 8 |
| `sbatch` stderr warnings confused chain controller | extract pure-numeric jobid via regex |
| System Python is 3.6 (EOL) | use cluster's `miniforge` module via `setup_python.sh` |

---