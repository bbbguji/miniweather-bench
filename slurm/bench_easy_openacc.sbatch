#!/bin/bash
#SBATCH --account=ACD115053
#SBATCH --partition=nycugpu_queue
#SBATCH --job-name=mw_e_ope
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=4
#SBATCH --gpus-per-node=8
#SBATCH --time=0-00:55:00
#SBATCH -o logs/easy_openacc_%j.log
#SBATCH -e logs/easy_openacc_%j.err

# Single-node GPU benchmark for openacc on easy size. NREPS=3.
set +e

BASE=${BASE:-$SLURM_SUBMIT_DIR}
[ -n "$BASE" ] && [ -d "$BASE" ] || { echo "ERROR: BASE invalid"; exit 1; }
[ -f "$BASE/config.sh" ] && source "$BASE/config.sh"

module purge
module load nvhpc-24.11_hpcx-2.20_cuda-12.6 2>/dev/null || \
  module load nvhpc-23.9_hpcx-2.16_cuda-12.2

export BASE
export RESULTS=$BASE/results/runs.csv
cd "$BASE"
source "$BASE/scripts/run_one.sh"
init_results_csv
NREPS=${NREPS:-3}
echo "==== bench_easy_openacc  NREPS=$NREPS  $(date) ===="

for gpus in 1 2 4 8; do
  for rep in $(seq 1 $NREPS); do
    run_openacc easy $gpus $rep
  done
done

echo "==== Done: $(date)   rows now in CSV: $(tail -n +2 $RESULTS | wc -l) ===="
