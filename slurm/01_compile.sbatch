#!/bin/bash
#SBATCH --account=ACD115053
#SBATCH --partition=nycugpu_queue
#SBATCH --job-name=mw_compile
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=1
#SBATCH --gpus-per-node=2
#SBATCH --time=0-00:30:00
#SBATCH -o logs/01_compile_%j.log
#SBATCH -e logs/01_compile_%j.err

# Build serial/mpi/openmp variants at 4 sizes:
#   easy / medium / hard  (benchmark sizes; sim_time=20 each)
#   canonical             (upstream strict-correctness test only)

set -e
module purge
module load gcc10/10.2.1
module load openmpi/5.0.2_ucx1.14.1_cuda12.3
module load cmake 2>/dev/null || module load cmake3 2>/dev/null || {
  echo "ERROR: no cmake module"; exit 1; }
command -v cmake >/dev/null || { echo "ERROR: cmake not in PATH"; exit 1; }

BASE=${BASE:-$SLURM_SUBMIT_DIR}
[ -n "$BASE" ] && [ -d "$BASE" ] || { echo "ERROR: BASE invalid"; exit 1; }
[ -f "$BASE/config.sh" ] && source "$BASE/config.sh"

PNETCDF_DIR=${PNETCDF_DIR:-$BASE/external/pnetcdf_install}
SRC=$BASE/miniWeather/c

cd "$BASE"
mkdir -p logs results

[ -d "$SRC" ] || { echo "ERROR: $SRC missing. Run setup.sh first."; exit 1; }
[ -d "$PNETCDF_DIR/lib" ] || { echo "ERROR: pnetcdf missing. Run 00_pnetcdf first."; exit 1; }

build_size() {
  local label=$1 nx=$2 nz=$3 sim_time=$4
  local bdir=$BASE/builds/$label
  echo
  echo "==== Build: $label (NX=$nx NZ=$nz SIM_TIME=$sim_time) ===="
  rm -rf "$bdir"
  mkdir -p "$bdir"
  cd "$bdir"
  cmake "$SRC" \
    -DCMAKE_CXX_COMPILER=mpic++ \
    -DCXXFLAGS="-O3 -march=native -DNO_INFORM -std=c++11 -I${PNETCDF_DIR}/include" \
    -DLDFLAGS="-L${PNETCDF_DIR}/lib -lpnetcdf" \
    -DOPENMP_FLAGS="-fopenmp" \
    -DNX=$nx -DNZ=$nz -DSIM_TIME=$sim_time \
    -DOUT_FREQ=-1 -DDATA_SPEC=DATA_SPEC_THERMAL \
    > cmake.log 2>&1 || { cat cmake.log; exit 1; }
  make -j 8 serial mpi openmp > make.log 2>&1 || {
    echo "WARN: some targets failed"; tail -30 make.log; }
  for t in serial mpi openmp; do
    [ -x "$bdir/$t" ] && echo "  [OK]   $bdir/$t" || echo "  [FAIL] $bdir/$t"
  done
}

build_size easy      1000  500 20
build_size medium    1600  800 20
build_size hard      2000 1000 20
build_size canonical  200  100 400

echo
echo "==== ALL BUILDS DONE ===="
ls -lh "$BASE"/builds/*/serial "$BASE"/builds/*/mpi "$BASE"/builds/*/openmp 2>&1 | tee "$BASE/results/build_summary.txt"
