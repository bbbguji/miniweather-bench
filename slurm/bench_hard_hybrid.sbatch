#!/bin/bash
#SBATCH --account=ACD115053
#SBATCH --partition=nycugpu_queue
#SBATCH --job-name=mw_h_hyb
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=1
#SBATCH --gpus-per-node=2
#SBATCH --time=0-00:25:00
#SBATCH -o logs/hard_hybrid_%j.log
#SBATCH -e logs/hard_hybrid_%j.err

# Benchmark: hard size, hybrid variant. Standalone-runnable.
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

echo "==== bench_hard_hybrid  NREPS=$NREPS  $(date) ===="


for cfg in "2 4" "4 2"; do
  read ranks threads <<< $cfg
  for rep in $(seq 1 $NREPS); do
    run_hybrid hard $ranks $threads $rep
  done
done

echo "==== Done: $(date)   rows now in CSV: $(tail -n +2 $RESULTS | wc -l) ===="
