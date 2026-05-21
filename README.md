# miniWeather Baseline (Taiwania 2 / contest_v100)

CPU baselines for [miniWeather](https://github.com/mrnorman/miniWeather)
on 台灣杉二號. Establishes reproducible serial / OpenMP / MPI / hybrid
references against which optimized variants (OpenMP-tuned, AVX-512, CUDA,
MPI+CUDA, …) will be compared in the final report.

---

## Baseline reference numbers (Team A's measurements)

Measured on `contest_v100` QOS (1 node, 8 cores). Median of 5 reps, all
runs `passed=true`. See `baseline_reference/` for raw data and plots.

### Speedup (8 cores vs serial)

| size | NX×NZ | serial (s) | best 8-core (s) | speedup | who wins @ 8 cores |
|------|-------|-----------|-----------------|---------|-------------------|
| easy | 400×200 | 4.70 | 0.658 | **7.13×** | mpi 8R (89% eff) |
| medium | 800×400 | 38.68 | 5.19 | **7.45×** | mpi 8R (93% eff) |
| hard | 1600×800 | 192.6 | 25.55 | **7.54×** | mpi 8R (94% eff) |

### Headline observations

* **mpi > openmp at large size** — at `hard`, mpi 8R = 7.54× vs openmp 8T = 6.83×, a 10% gap.
  This is the NUMA-locality + cache-line ownership advantage of separate processes
  over shared-memory threads on memory-bound code.
* **OpenMP 1T overhead** — openmp at 1 thread is ~8% slower than serial
  (41.86s vs 38.68s @ medium). This is OpenMP runtime fork/join cost
  that doesn't exist in pure serial. It becomes an optimization target
  for the OpenMP-tuned variant.
* **Hybrid (2R×4T or 4R×2T) ≈ mpi 8R or openmp 8T** — neither hurts nor helps.

### Strict correctness check (upstream canonical: NX=200, NZ=100, sim_time=400)

All 4 variants pass upstream's strict thresholds (`|d_mass| < 1e-13`,
`d_te ∈ (-4.5e-5, 0)`):

| variant | d_mass | d_te |
|---------|--------|------|
| serial | -7.4e-15 | -3.978e-05 |
| openmp 8T | -1.2e-14 | -3.978e-05 |
| mpi 8R | -1.2e-15 | -3.978e-05 |
| hybrid 2R×4T | -7.8e-16 | -3.978e-05 |

All four variants compute **algebraically equivalent** answers
(d_te identical to 4 significant figures) — strong evidence of correctness.

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

# 5. Build all binaries (~5 min)
sbatch slurm/01_compile.sbatch

# 6. Sanity check (~3 min) — do this BEFORE the full sweep
sbatch slurm/02_smoke.sbatch

# 7. Strict correctness check (~5 min) — proves implementation is bug-free
sbatch slurm/check_correctness.sbatch

# 8. Run benchmarks — choose ONE workflow:

# 8a. Single benchmark (fast, recommended for development)
sbatch slurm/bench_medium_openmp.sbatch
sbatch slurm/bench_hard_mpi.sbatch

# 8b. Full sweep — sequential controller (2–4 hr depending on queue)
tmux new -s mw
bash submit_chain.sh
# Ctrl-b d to detach ; `tmux attach -t mw` to reattach

# 9. Analyze
bash setup_python.sh         # one-time: install pandas/numpy/matplotlib
source venv/bin/activate
python3 scripts/analyze.py
```

---

## Problem sizes

| label | NX × NZ | sim_time | use |
|-------|---------|----------|-----|
| easy | 400×200 | 20 | smoke test / fast development |
| medium | 800×400 | 20 | **main** benchmark (best efficiency) |
| hard | 1600×800 | 12 | memory-bandwidth stress |
| canonical | 200×100 | 400 | strict correctness only (upstream test) |

Override repetition count: `NREPS=3 sbatch slurm/bench_medium_openmp.sbatch`

---

## File layout

```
.
├── config.sh                    # SLURM account / partition
├── setup.sh                     # one-time: clone miniWeather, check pnetcdf
├── setup_python.sh              # one-time: install Python deps in venv/
├── submit_chain.sh              # sequential controller (one job at a time)
├── README.md
├── slurm/
│   ├── 00_pnetcdf.sbatch        # build PnetCDF (one-time)
│   ├── 01_compile.sbatch        # build all binaries
│   ├── 02_smoke.sbatch          # 1-rep sanity check
│   ├── check_correctness.sbatch # strict upstream-spec validation
│   └── bench_<size>_<variant>.sbatch
│        # size    ∈ {easy, medium, hard}
│        # variant ∈ {serial, openmp, mpi, hybrid}
│        # 12 standalone benchmark files
├── scripts/
│   ├── run_one.sh               # helpers sourced by sbatch
│   └── analyze.py               # statistics + plots
├── baseline_reference/          # ← committed: Team A's reference data
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
└── venv/                        # gitignored — Python virtualenv
```

---

## For teammates adding optimized variants

The baseline above is what you're trying to beat. Your variant is
"successful" if its `Mcells_per_sec` exceeds the corresponding baseline
at the same size + same total cores.

### Steps

1. **Build** your variant as `builds/<size>/<your_variant>` for each
   size you support.
2. **Add a runner** in `scripts/run_one.sh`:
   ```bash
   run_my_variant() {
     local size=$1 rep=$2 [...]
     [...]
     parse_and_log "$out" my_variant $size $nx $nz $st [...]
   }
   ```
3. **Write an sbatch** `slurm/bench_<size>_<your_variant>.sbatch`
   (copy from any existing bench_*.sbatch).
4. **Use a unique variant name**. Reserved: `serial`, `mpi`, `openmp`,
   `hybrid`. Suggested: `openmp_tuned`, `cuda`, `mpi_cuda`, `avx512`.
5. **Run with `NREPS=5`** for fair comparison.
6. `analyze.py` will auto-pick up new variants and plot them alongside
   the baseline.

### Validation expectations

Your variant must produce `passed=true` for at least the sizes you
benchmark. Strongly recommended: also run `check_correctness.sbatch`-
equivalent with your variant on the canonical size to prove
correctness, not just absence of NaN.

---

## How validation works

This repo has **two correctness checks**:

1. **Benchmark runs** (`results/runs.csv` / `baseline_reference/runs.csv`)
   — uses easy/medium/hard sizes tuned for performance measurement.
   Validation is catastrophic-only (`|d_mass| < 1e-8`, `|d_te| < 1e-2`).
   Catches NaN, instability, broken algorithms. Allows mild FP error
   accumulation across larger problem sizes.

2. **Strict correctness** (`results/correctness.csv` /
   `baseline_reference/correctness.csv`) — runs upstream's canonical
   test (NX=200, NZ=100, sim_time=400) with **upstream-strict
   thresholds** (`|d_mass| < 1e-13`, `d_te ∈ (-4.5e-5, 0)`). Proves
   the implementation is mathematically equivalent to the reference.

A new variant should pass **both**.

---

## Known cluster quirks (already worked around)

| Quirk | Fix in this repo |
|-------|----------|
| OpenMPI 5 aborts because `OMPI_MCA_opal_cuda_support=1` is set by the module but library lacks CUDA | `run_one.sh` sets it to 0 |
| Slurm's `MpiDefault=pmi2` causes OpenMPI 5 ranks to launch in **singleton mode** (each rank thinks it's rank 0; no real domain decomposition!) | All `srun` calls pass `--mpi=pmix`. There is also a runtime detector in `parse_and_log` that warns if it happens again. |
| `--exclusive` not allowed | not used |
| QOS caps CPUs at 8 | thread/rank counts capped at 8 |
| `sbatch` stderr warnings (e.g. `--exclusive removed`) confused the chain controller | extract pure-numeric jobid via regex |

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| `QOSMaxSubmitJobPerUserLimit` | another `mw_*` job in queue: `squeue -u $USER` |
| `QOSMaxWallDurationPerJobLimit` | sbatch `--time` > 30 min |
| smoke test all `passed=false` | `cat logs/runs/*.out` — likely MPI launch error |
| 8R timing ≈ 1R timing (no scaling) | MPI in singleton mode. Verify `srun --mpi=pmix`. Each raw log should print `nx_glob:` exactly once for any rank count |
| variance > 15% between reps | other jobs sharing your node (can't fix without `--exclusive`) |

