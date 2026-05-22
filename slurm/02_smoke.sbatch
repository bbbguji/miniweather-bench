#!/bin/bash
#SBATCH --account=ACD115053
#SBATCH --partition=nycugpu_queue
#SBATCH --job-name=mw_smoke
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=1
#SBATCH --gpus-per-node=2
#SBATCH --time=0-00:30:00
#SBATCH -o logs/02_smoke_%j.log
#SBATCH -e logs/02_smoke_%j.err

# Quick sanity check: 1 rep per variant on easy size.
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

echo "==== SMOKE TEST (easy, 1 rep each) ===="

run_serial easy 1
run_openmp easy 1 1
run_openmp easy 4 1
run_openmp easy 8 1
run_mpi    easy 1 1
run_mpi    easy 4 1
run_mpi    easy 8 1
run_hybrid easy 2 4 1

echo
echo "==== Smoke summary ===="
tail -n +2 "$RESULTS" | awk -F, '$3=="easy" {printf "%-8s %2dR x %2dT  wall=%-8s passed=%s\n", $2,$8,$9,$12,$15}'
fail=$(tail -n +2 "$RESULTS" | awk -F, '$3=="easy" && $15!="true"' | wc -l)
total=$(tail -n +2 "$RESULTS" | awk -F, '$3=="easy"' | wc -l)
echo "Validation: $((total-fail))/$total passed"
[ $fail -gt 0 ] && { echo "ERROR: smoke failures"; exit 1; }
echo "SMOKE PASSED."
