#!/bin/bash
#SBATCH --account=ACD115053
#SBATCH --partition=nycugpu_queue
#SBATCH --job-name=mw_h_omp
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=1
#SBATCH --gpus-per-node=2
#SBATCH --time=0-00:25:00
#SBATCH -o logs/hard_openmp_%j.log
#SBATCH -e logs/hard_openmp_%j.err

# Benchmark: hard size, openmp variant. Standalone-runnable.
# Repeat count from $NREPS env var (default 5).
set +e
module purge
module load gcc10/10.2.1
module load openmpi/5.0.2_ucx1.14.1_cuda12.3

BASE=${BASE:-$SLURM_SUBMIT_DIR}
[ -n "$BASE" ] && [ -d "$BASE" ] || { echo "ERROR: BASE invalid: '$BASE'"; exit 1; }
[ -f "$BASE/config.sh" ] && source "$BASE/config.sh"

export BASE
export RESULTS=$BASE/results/runs.csv
cd "$BASE"
source "$BASE/scripts/run_one.sh"
init_results_csv

NREPS=${NREPS:-5}

echo "==== bench_hard_openmp  NREPS=$NREPS  $(date) ===="


# Hard OpenMP: skip 1T (too slow), do 2/4/8T
for threads in 2 4 8; do
  for rep in $(seq 1 $NREPS); do
    run_openmp hard $threads $rep
  done
done

echo "==== Done: $(date)   rows now in CSV: $(tail -n +2 $RESULTS | wc -l) ===="
