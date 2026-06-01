#!/bin/bash
#SBATCH --account=ACD115053
#SBATCH --partition=nycugpu_queue
#SBATCH --job-name=mw_m_ope2
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=4
#SBATCH --gpus-per-node=8
#SBATCH --time=0-00:55:00
#SBATCH -o logs/medium_openacc_2n_%j.log
#SBATCH -e logs/medium_openacc_2n_%j.err

# Two-node GPU benchmark: openacc on medium. Up to 16 GPUs.
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
echo "==== bench2n_medium_openacc  NREPS=$NREPS  $(date) ===="

for ranks in 8 16; do
  for rep in $(seq 1 $NREPS); do
    run_openacc medium $ranks $rep 2
  done
done

echo "==== Done: $(date)   rows now in CSV: $(tail -n +2 $RESULTS | wc -l) ===="
