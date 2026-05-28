#!/bin/bash
#SBATCH --account=ACD115053
#SBATCH --partition=nycugpu_queue
#SBATCH --job-name=mw_h_mpi
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=32
#SBATCH --cpus-per-task=1
#SBATCH --gpus-per-node=8
#SBATCH --time=0-00:55:00
#SBATCH -o logs/hard_mpi_%j.log
#SBATCH -e logs/hard_mpi_%j.err

# Single-node benchmark: hard size, mpi variant. NREPS=3.
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
NREPS=${NREPS:-3}
echo "==== bench_hard_mpi  NREPS=$NREPS  $(date) ===="


for ranks in 2 4 8 16 32; do
  for rep in $(seq 1 $NREPS); do run_mpi hard $ranks $rep; done
done

echo "==== Done: $(date)   rows now in CSV: $(tail -n +2 $RESULTS | wc -l) ===="
