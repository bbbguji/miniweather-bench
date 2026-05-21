#!/bin/bash
#SBATCH --account=ACD115053
#SBATCH --partition=nycugpu_queue
#SBATCH --job-name=mw_verify
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=1
#SBATCH --gpus-per-node=2
#SBATCH --time=0-00:10:00
#SBATCH -o logs/verify_pmix_%j.log
#SBATCH -e logs/verify_pmix_%j.err

# Verify the --mpi=pmix fix made MPI actually scale.
# Should see ~5s for r8 vs ~38s before fix.
set +e
module purge
module load gcc10/10.2.1
module load openmpi/5.0.2_ucx1.14.1_cuda12.3

BASE=${BASE:-$SLURM_SUBMIT_DIR}
export BASE
export RESULTS=$BASE/results/verify_pmix.csv

cd "$BASE"
source "$BASE/scripts/run_one.sh"
init_results_csv

echo "==== Verify pmix fix: medium MPI scaling, 1 rep each ===="
for ranks in 1 2 4 8; do
  run_mpi medium $ranks 99
done

echo
echo "==== SUMMARY (medium MPI before vs after) ===="
echo "Expected after fix:"
echo "  1R: ~38s, 2R: ~20s, 4R: ~10s, 8R: ~5s"
echo
echo "Actual:"
tail -n +2 $RESULTS | awk -F, '{printf "  %2dR: %ss  passed=%s\n", $8, $12, $15}'
