#!/bin/bash
#SBATCH --account=ACD115053
#SBATCH --partition=nycugpu_queue
#SBATCH --job-name=mw_check
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=1
#SBATCH --gpus-per-node=2
#SBATCH --time=0-00:15:00
#SBATCH -o logs/check_correctness_%j.log
#SBATCH -e logs/check_correctness_%j.err

# Formal correctness check using upstream miniWeather's canonical test settings:
#   NX=200, NZ=100, SIM_TIME=400, DATA_SPEC_THERMAL
#
# Per upstream docs (https://github.com/mrnorman/miniWeather):
#   - C/double precision: |d_mass| MUST be < 1e-13
#   - d_te MUST be negative, magnitude < 4.5e-5
#
# This is a one-shot validation. Distinct from runs.csv (which uses
# benchmark-tuned sizes that allow accumulated FP error to exceed 1e-13).

set +e
module purge
module load gcc10/10.2.1
module load openmpi/5.0.2_ucx1.14.1_cuda12.3

BASE=${BASE:-$SLURM_SUBMIT_DIR}
[ -n "$BASE" ] && [ -d "$BASE" ] || { echo "ERROR: BASE invalid"; exit 1; }
[ -f "$BASE/config.sh" ] && source "$BASE/config.sh"

export BASE
export RESULTS=$BASE/results/correctness.csv  # separate from runs.csv

cd "$BASE"
source "$BASE/scripts/run_one.sh"

# Start a fresh correctness CSV
rm -f "$RESULTS"
init_results_csv

echo "==== CORRECTNESS CHECK (canonical: NX=200, NZ=100, SIM_TIME=400) ===="
echo "==== Started: $(date) ===="

# Verify canonical binaries exist
for variant in serial mpi openmp; do
  if [ ! -x "$BASE/builds/canonical/$variant" ]; then
    echo "ERROR: $BASE/builds/canonical/$variant missing."
    echo "Rebuild with the updated 01_compile.sbatch first."
    exit 1
  fi
done

run_serial canonical 1
run_openmp canonical 8 1
run_mpi    canonical 8 1
run_hybrid canonical 2 4 1

echo
echo "==== STRICT VALIDATION (upstream thresholds) ===="
python3 <<'PY_EOF'
import csv, sys, os
csv_path = os.environ['RESULTS']
print(f"Reading: {csv_path}\n")

rows = []
with open(csv_path) as f:
    for r in csv.DictReader(f):
        if r['size'] == 'canonical':
            rows.append(r)

if not rows:
    print("ERROR: no canonical-size rows found in CSV")
    sys.exit(1)

# upstream thresholds (docs: docs/INSTALL.md "Checking for Correctness")
MASS_LIMIT = 1e-13      # strict for C/double precision
ENERGY_MIN = -4.5e-5    # must be negative, magnitude < 4.5e-5

print(f"{'Variant':<10} {'Config':<12} {'d_mass':>14} {'mass_OK':>8} "
      f"{'d_te':>14} {'te_OK':>8}")
print("-" * 70)

fails = []
for r in rows:
    dm = float(r['d_mass'])
    de = float(r['d_te'])
    label_v = r['variant']
    label_c = f"{r['ranks']}R x {r['threads_per_rank']}T"

    ok_m = abs(dm) < MASS_LIMIT
    ok_e = (de < 0) and (de > ENERGY_MIN)

    print(f"{label_v:<10} {label_c:<12} {dm:>14.6e} {'OK' if ok_m else 'FAIL':>8} "
          f"{de:>14.6e} {'OK' if ok_e else 'FAIL':>8}")

    if not (ok_m and ok_e):
        fails.append(f"{label_v} {label_c}")

print("-" * 70)
print(f"Mass threshold:   |d_mass| < {MASS_LIMIT:.0e}")
print(f"Energy threshold: {ENERGY_MIN:.2e} < d_te < 0\n")

if fails:
    print(f"FAILED ({len(fails)} variant(s)):")
    for f in fails:
        print(f"  {f}")
    sys.exit(1)
else:
    print("ALL VARIANTS PASS STRICT UPSTREAM CORRECTNESS THRESHOLDS")
PY_EOF

rc=$?
echo
echo "==== Done: $(date) ===="
exit $rc
