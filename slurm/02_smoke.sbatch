#!/bin/bash
#SBATCH --account=ACD115053
#SBATCH --partition=nycugpu_queue
#SBATCH --job-name=mw_smoke
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=32
#SBATCH --cpus-per-task=1
#SBATCH --gpus-per-node=8
#SBATCH --time=0-00:30:00
#SBATCH -o logs/02_smoke_%j.log
#SBATCH -e logs/02_smoke_%j.err

# Quick sanity check: 1 rep per variant on EASY size.
# Writes to a DEDICATED smoke.csv (clobbered each run) so stale data
# from previous attempts can't trip the validation.
set +e
module purge
module load gcc10/10.2.1
module load openmpi/5.0.2_ucx1.14.1_cuda12.3

BASE=${BASE:-$SLURM_SUBMIT_DIR}
[ -n "$BASE" ] && [ -d "$BASE" ] || { echo "ERROR: BASE invalid"; exit 1; }
[ -f "$BASE/config.sh" ] && source "$BASE/config.sh"

export BASE
export RESULTS=$BASE/results/smoke.csv

cd "$BASE"
mkdir -p results
rm -f "$RESULTS"

source "$BASE/scripts/run_one.sh"
init_results_csv

echo "==== SMOKE TEST (easy, 1 rep each) ===="

run_serial easy 1
run_openmp easy 8 1
run_openmp easy 32 1
run_mpi    easy 8 1
run_mpi    easy 32 1
run_hybrid easy 4 8 1

# CSV columns (17 total in current schema):
#  1=timestamp 2=variant 3=size 4=nx 5=nz 6=sim_time 7=nodes 8=ranks
#  9=threads_per_rank 10=total_cores 11=gpus 12=run_id 13=wall_time_s
# 14=d_mass 15=d_te 16=passed 17=raw_log
echo
echo "==== Smoke summary (this run only) ===="
tail -n +2 "$RESULTS" | awk -F, '{printf "%-8s %2dR x %2dT  wall=%-8s passed=%s\n", $2,$8,$9,$13,$16}'

fail=$(tail -n +2 "$RESULTS" | awk -F, '$16!="true"' | wc -l)
total=$(tail -n +2 "$RESULTS" | wc -l)
echo "Validation: $((total-fail))/$total passed"
[ $fail -gt 0 ] && { echo "ERROR: smoke failures"; exit 1; }
echo "SMOKE PASSED."
