#!/bin/bash
#SBATCH --account=ACD115053
#SBATCH --partition=nycugpu_queue
#SBATCH --job-name=mw_compile
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=1
#SBATCH --gpus-per-node=2
#SBATCH --time=0-00:55:00
#SBATCH -o logs/01_compile_%j.log
#SBATCH -e logs/01_compile_%j.err

# Build all 5 variants at 4 sizes:
#   variants: serial / mpi / openmp / openmp45 / openacc
#   sizes:    easy / medium / hard (sim_time=20) and canonical (sim_time=400)
#
# CPU variants (serial/mpi/openmp) build with GCC10 + OpenMPI 5.
# GPU variants (openmp45/openacc) build with NVHPC (nvc++) which has its
# own OpenMPI - we use a SEPARATE build dir to keep that hpcx OpenMPI
# from polluting the CPU runs.

set -e

BASE=${BASE:-$SLURM_SUBMIT_DIR}
[ -n "$BASE" ] && [ -d "$BASE" ] || { echo "ERROR: BASE invalid"; exit 1; }
[ -f "$BASE/config.sh" ] && source "$BASE/config.sh"

PNETCDF_DIR=${PNETCDF_DIR:-$BASE/external/pnetcdf_install}
SRC=$BASE/miniWeather/c

cd "$BASE"
mkdir -p logs results

[ -d "$SRC" ] || { echo "ERROR: $SRC missing. Run setup.sh first."; exit 1; }
[ -d "$PNETCDF_DIR/lib" ] || { echo "ERROR: pnetcdf missing. Run 00_pnetcdf first."; exit 1; }

# ---------- CPU variants: serial / mpi / openmp ----------
build_cpu_size() {
  local label=$1 nx=$2 nz=$3 sim_time=$4
  local bdir=$BASE/builds/$label
  echo
  echo "==== CPU build: $label (NX=$nx NZ=$nz SIM_TIME=$sim_time) ===="

  module purge
  module load gcc10/10.2.1
  module load openmpi/5.0.2_ucx1.14.1_cuda12.3
  module load cmake 2>/dev/null || module load cmake3 2>/dev/null

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
    echo "WARN: CPU make had failures"; tail -30 make.log; }
  for t in serial mpi openmp; do
    [ -x "$bdir/$t" ] && echo "  [OK]   $bdir/$t" || echo "  [FAIL] $bdir/$t"
  done
}

# ---------- GPU variants: openmp45 / openacc ----------
# Use nvhpc which has both an OpenACC-capable compiler and OpenMP target
# offload, plus its own bundled OpenMPI (in hpcx).
build_gpu_size() {
  local label=$1 nx=$2 nz=$3 sim_time=$4
  local bdir=$BASE/builds/${label}_gpu
  echo
  echo "==== GPU build: $label (NX=$nx NZ=$nz SIM_TIME=$sim_time) ===="

  module purge
  # NVHPC bundles its own OpenMPI in hpcx — load it once and use mpic++
  if ! module load nvhpc-24.11_hpcx-2.20_cuda-12.6 2>/dev/null; then
    echo "  [skip] nvhpc-24.11_hpcx-2.20_cuda-12.6 not available; trying older"
    module load nvhpc-23.9_hpcx-2.16_cuda-12.2 2>/dev/null || {
      echo "  [error] no nvhpc module found"
      return 1
    }
  fi
  module load cmake 2>/dev/null || module load cmake3 2>/dev/null

  rm -rf "$bdir"
  mkdir -p "$bdir"
  cd "$bdir"

  # NVHPC flags:
  #   -acc=gpu          -> OpenACC for GPU
  #   -mp=gpu           -> OpenMP target offload for GPU
  #   -gpu=cc70         -> Volta (V100) compute capability
  #   -Minfo=accel      -> show offload info (uncomment when debugging)
  cmake "$SRC" \
    -DCMAKE_CXX_COMPILER=mpic++ \
    -DCXXFLAGS="-O3 -DNO_INFORM -std=c++11 -I${PNETCDF_DIR}/include" \
    -DLDFLAGS="-L${PNETCDF_DIR}/lib -lpnetcdf" \
    -DOPENACC_FLAGS="-acc=gpu -gpu=cc70" \
    -DOPENMP45_FLAGS="-mp=gpu -gpu=cc70" \
    -DNX=$nx -DNZ=$nz -DSIM_TIME=$sim_time \
    -DOUT_FREQ=-1 -DDATA_SPEC=DATA_SPEC_THERMAL \
    > cmake.log 2>&1 || { cat cmake.log; exit 1; }
  make -j 8 openmp45 openacc > make.log 2>&1 || {
    echo "WARN: GPU make had failures"; tail -40 make.log; }
  for t in openmp45 openacc; do
    [ -x "$bdir/$t" ] && echo "  [OK]   $bdir/$t" || echo "  [FAIL] $bdir/$t"
  done
}

# ---------- Build everything ----------
build_cpu_size easy      1000  500 20
build_cpu_size medium    1600  800 20
build_cpu_size hard      2000 1000 20
build_cpu_size canonical  200  100 400

build_gpu_size easy      1000  500 20
build_gpu_size medium    1600  800 20
build_gpu_size hard      2000 1000 20
build_gpu_size canonical  200  100 400

echo
echo "==== ALL BUILDS DONE ===="
echo "  CPU binaries:"
ls -lh "$BASE"/builds/*/serial "$BASE"/builds/*/mpi "$BASE"/builds/*/openmp 2>/dev/null
echo "  GPU binaries:"
ls -lh "$BASE"/builds/*_gpu/openmp45 "$BASE"/builds/*_gpu/openacc 2>/dev/null
