#!/bin/bash
#SBATCH --account=ACD115053
#SBATCH --partition=nycugpu_queue
#SBATCH --job-name=mw_check
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=32
#SBATCH --cpus-per-task=1
#SBATCH --gpus-per-node=8
#SBATCH --time=0-00:30:00
#SBATCH -o logs/check_correctness_%j.log
#SBATCH -e logs/check_correctness_%j.err

# Formal correctness check using upstream miniWeather's canonical test
# (NX=200, NZ=100, SIM_TIME=400). Applies upstream's STRICT thresholds:
#   |d_mass| < 1e-13
#   d_te < 0 and |d_te| < 4.5e-5
#
# Writes to results/correctness.csv (separate from benchmark runs.csv).
set +e
module purge
module load gcc10/10.2.1
module load openmpi/5.0.2_ucx1.14.1_cuda12.3

BASE=${BASE:-$SLURM_SUBMIT_DIR}
[ -n "$BASE" ] && [ -d "$BASE" ] || { echo "ERROR: BASE invalid"; exit 1; }
[ -f "$BASE/config.sh" ] && source "$BASE/config.sh"

export BASE
export RESULTS=$BASE/results/correctness.csv
cd "$BASE"
source "$BASE/scripts/run_one.sh"
rm -f "$RESULTS"
init_results_csv

echo "==== CORRECTNESS CHECK (canonical: NX=200 NZ=100 SIM_TIME=400) ===="
echo "==== Started: $(date) ===="

for variant in serial mpi openmp; do
  [ -x "$BASE/builds/canonical/$variant" ] || {
    echo "ERROR: $BASE/builds/canonical/$variant missing — rebuild needed"
    exit 1
  }
done

run_serial canonical 1
run_openmp canonical 32 1
run_mpi    canonical 32 1
run_hybrid canonical 4 8 1

echo
echo "==== STRICT VALIDATION (upstream thresholds) ===="
python3 <<'PY_EOF'
import csv, sys, os
csv_path = os.environ['RESULTS']
print(f"Reading: {csv_path}\n")

rows = [r for r in csv.DictReader(open(csv_path)) if r['size'] == 'canonical']
if not rows:
    print("ERROR: no canonical rows in CSV"); sys.exit(1)

MASS_LIMIT = 1e-13
ENERGY_MIN = -4.5e-5

print(f"{'Variant':<10} {'Config':<14} {'d_mass':>14} {'mass_OK':>8} "
      f"{'d_te':>14} {'te_OK':>8}")
print("-" * 74)

fails = []
for r in rows:
    dm = float(r['d_mass']); de = float(r['d_te'])
    cfg = f"{r['ranks']}R x {r['threads_per_rank']}T"
    ok_m = abs(dm) < MASS_LIMIT
    ok_e = (de < 0) and (de > ENERGY_MIN)
    print(f"{r['variant']:<10} {cfg:<14} {dm:>14.6e} {'OK' if ok_m else 'FAIL':>8} "
          f"{de:>14.6e} {'OK' if ok_e else 'FAIL':>8}")
    if not (ok_m and ok_e):
        fails.append(f"{r['variant']} {cfg}")

print("-" * 74)
print(f"Mass threshold:   |d_mass| < {MASS_LIMIT:.0e}")
print(f"Energy threshold: {ENERGY_MIN:.2e} < d_te < 0\n")

if fails:
    print(f"FAILED ({len(fails)}):")
    for f in fails: print(f"  {f}")
    sys.exit(1)
print("ALL VARIANTS PASS STRICT UPSTREAM CORRECTNESS THRESHOLDS")
PY_EOF

rc=$?
echo
echo "==== Done: $(date) ===="
exit $rc
