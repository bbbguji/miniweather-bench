#!/bin/bash
#SBATCH --account=ACD115053
#SBATCH --partition=nycugpu_queue
#SBATCH --job-name=mw_viz
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=4
#SBATCH --gpus-per-node=8
#SBATCH --time=0-00:55:00
#SBATCH -o logs/make_video_data_%j.log
#SBATCH -e logs/make_video_data_%j.err

# Build a viz binary (OUT_FREQ != -1) for the chosen size+variant and run
# it to produce results/viz/output_<size>_<variant>.nc.
# Benchmark binaries have OUT_FREQ=-1 so cannot be reused.
#
# Usage:
#   sbatch slurm/make_video_data.sbatch                     # default: easy + mpi (CPU)
#   VIZ_SIZE=medium sbatch slurm/make_video_data.sbatch
#   VIZ_VARIANT=openacc VIZ_SIZE=hard sbatch slurm/make_video_data.sbatch  # GPU
#
# Env overrides:
#   VIZ_SIZE      label                        (default: easy)   easy/medium/hard/custom
#   VIZ_VARIANT   which source variant         (default: mpi)
#                 CPU: serial / mpi / openmp
#                 GPU: openmp45 / openacc
#   VIZ_NX/NZ     grid (default from preset)
#   VIZ_SIM_TIME  sim seconds                  (default: 20)
#   VIZ_OUT_FREQ  output every N sim-sec       (default: 0.5)
#   VIZ_RANKS     MPI ranks                    (default: 8 for CPU, =GPU count for GPU)
#   VIZ_GPUS      GPUs for GPU variants        (default: 1)

set -e

BASE=${BASE:-$SLURM_SUBMIT_DIR}
[ -n "$BASE" ] && [ -d "$BASE" ] || { echo "ERROR: BASE invalid"; exit 1; }
[ -f "$BASE/config.sh" ] && source "$BASE/config.sh"

PNETCDF_DIR=${PNETCDF_DIR:-$BASE/external/pnetcdf_install}
SRC=$BASE/miniWeather/c

VIZ_SIZE=${VIZ_SIZE:-easy}
VIZ_VARIANT=${VIZ_VARIANT:-mpi}

# Validate variant
case "$VIZ_VARIANT" in
  serial|mpi|openmp)          FAMILY=cpu ;;
  openmp45|openacc)           FAMILY=gpu ;;
  *)
    echo "ERROR: unknown VIZ_VARIANT=$VIZ_VARIANT"
    echo "  CPU: serial / mpi / openmp"
    echo "  GPU: openmp45 / openacc"
    exit 1
    ;;
esac

# Pick size preset
case "$VIZ_SIZE" in
  easy)
    : ${VIZ_NX:=1000} ; : ${VIZ_NZ:=500}
    : ${VIZ_SIM_TIME:=20} ; : ${VIZ_OUT_FREQ:=0.5}
    ;;
  medium)
    : ${VIZ_NX:=1600} ; : ${VIZ_NZ:=800}
    : ${VIZ_SIM_TIME:=20} ; : ${VIZ_OUT_FREQ:=0.5}
    ;;
  hard)
    : ${VIZ_NX:=2000} ; : ${VIZ_NZ:=1000}
    : ${VIZ_SIM_TIME:=20} ; : ${VIZ_OUT_FREQ:=0.5}
    ;;
  custom)
    for v in VIZ_NX VIZ_NZ VIZ_SIM_TIME VIZ_OUT_FREQ; do
      [ -z "${!v:-}" ] && { echo "ERROR: VIZ_SIZE=custom requires $v"; exit 1; }
    done
    ;;
  *)
    echo "ERROR: unknown VIZ_SIZE=$VIZ_SIZE (easy/medium/hard/custom)"
    exit 1
    ;;
esac

# Pick default ranks/gpus based on family
if [ "$FAMILY" = "cpu" ]; then
  : ${VIZ_RANKS:=8}
  VIZ_GPUS=0
  VIZ_DIR=$BASE/builds/viz_${VIZ_SIZE}/$VIZ_VARIANT
else
  : ${VIZ_GPUS:=1}
  : ${VIZ_RANKS:=$VIZ_GPUS}      # 1 rank per GPU convention
  VIZ_DIR=$BASE/builds/viz_${VIZ_SIZE}_gpu/$VIZ_VARIANT
fi

RUN_DIR=$BASE/results/viz
OUTPUT_NC=output_${VIZ_SIZE}_${VIZ_VARIANT}.nc

echo "==== Viz params ===="
echo "  size          = $VIZ_SIZE"
echo "  variant       = $VIZ_VARIANT  (family: $FAMILY)"
echo "  NX × NZ       = $VIZ_NX × $VIZ_NZ"
echo "  SIM_TIME      = $VIZ_SIM_TIME"
echo "  OUT_FREQ      = $VIZ_OUT_FREQ"
echo "  Frames ≈ $(echo "$VIZ_SIM_TIME / $VIZ_OUT_FREQ" | bc -l | awk '{printf "%.0f", $1}')"
echo "  Ranks         = $VIZ_RANKS"
echo "  GPUs          = $VIZ_GPUS"
echo "  Build dir     = $VIZ_DIR"
echo "  Output        = $RUN_DIR/$OUTPUT_NC"

# ------------------------------------------------------------------
# Load toolchain (CPU = gcc10+openmpi5; GPU = nvhpc bundled hpcx)
# ------------------------------------------------------------------
module purge
if [ "$FAMILY" = "cpu" ]; then
  module load gcc10/10.2.1
  module load openmpi/5.0.2_ucx1.14.1_cuda12.3
else
  module load nvhpc-24.11_hpcx-2.20_cuda-12.6 2>/dev/null || \
    module load nvhpc-23.9_hpcx-2.16_cuda-12.2
fi
module load cmake 2>/dev/null || module load cmake3 2>/dev/null
export OMPI_MCA_opal_cuda_support=0

# ------------------------------------------------------------------
# Compile if needed (cached by SIG = NX_NZ_SIM_OUTFREQ)
# ------------------------------------------------------------------
SIG="${VIZ_NX}_${VIZ_NZ}_${VIZ_SIM_TIME}_${VIZ_OUT_FREQ}"
SIG_FILE=$VIZ_DIR/.sig
need_compile=1
if [ -f "$SIG_FILE" ] && [ -x "$VIZ_DIR/$VIZ_VARIANT" ]; then
  [ "$(cat $SIG_FILE)" = "$SIG" ] && need_compile=0
fi

if [ "$need_compile" = "1" ]; then
  echo
  echo "==== Compiling viz binary: $VIZ_VARIANT ($VIZ_SIZE, $FAMILY) ===="
  rm -rf "$VIZ_DIR"
  mkdir -p "$VIZ_DIR"
  cd "$VIZ_DIR"

  if [ "$FAMILY" = "cpu" ]; then
    cmake "$SRC" \
      -DCMAKE_CXX_COMPILER=mpic++ \
      -DCXXFLAGS="-O3 -march=native -DNO_INFORM -std=c++11 -I${PNETCDF_DIR}/include" \
      -DLDFLAGS="-L${PNETCDF_DIR}/lib -lpnetcdf" \
      -DOPENMP_FLAGS="-fopenmp" \
      -DNX=$VIZ_NX -DNZ=$VIZ_NZ \
      -DSIM_TIME=$VIZ_SIM_TIME \
      -DOUT_FREQ=$VIZ_OUT_FREQ \
      -DDATA_SPEC=DATA_SPEC_THERMAL \
      > cmake.log 2>&1 || { cat cmake.log; exit 1; }
  else
    cmake "$SRC" \
      -DCMAKE_CXX_COMPILER=mpic++ \
      -DCXXFLAGS="-O3 -DNO_INFORM -std=c++11 -I${PNETCDF_DIR}/include" \
      -DLDFLAGS="-L${PNETCDF_DIR}/lib -lpnetcdf" \
      -DOPENACC_FLAGS="-acc=gpu -gpu=cc70" \
      -DOPENMP45_FLAGS="-mp=gpu -gpu=cc70" \
      -DNX=$VIZ_NX -DNZ=$VIZ_NZ \
      -DSIM_TIME=$VIZ_SIM_TIME \
      -DOUT_FREQ=$VIZ_OUT_FREQ \
      -DDATA_SPEC=DATA_SPEC_THERMAL \
      > cmake.log 2>&1 || { cat cmake.log; exit 1; }
  fi

  make -j 8 $VIZ_VARIANT > make.log 2>&1 || { tail -40 make.log; exit 1; }
  [ -x "$VIZ_DIR/$VIZ_VARIANT" ] || { echo "ERROR: $VIZ_VARIANT binary not produced"; exit 1; }
  echo "$SIG" > "$SIG_FILE"
  echo "  [OK]   $VIZ_DIR/$VIZ_VARIANT"
else
  echo "==== Viz binary already compiled (sig=$SIG) ===="
fi

# ------------------------------------------------------------------
# Run
# ------------------------------------------------------------------
mkdir -p "$RUN_DIR"
cd "$RUN_DIR"
rm -f output.nc "$OUTPUT_NC"

echo
echo "==== Running ($VIZ_VARIANT, ranks=$VIZ_RANKS) in $RUN_DIR ===="
if [ "$FAMILY" = "cpu" ]; then
  srun --mpi=pmix --ntasks=$VIZ_RANKS --cpus-per-task=1 \
       --cpu-bind=cores "$VIZ_DIR/$VIZ_VARIANT"
else
  srun --mpi=pmix --ntasks=$VIZ_RANKS --cpus-per-task=4 \
       --gpus-per-task=1 "$VIZ_DIR/$VIZ_VARIANT"
fi

[ -f output.nc ] || { echo "ERROR: output.nc not produced"; exit 1; }
mv output.nc "$OUTPUT_NC"

echo
echo "==== Result ===="
ls -lh "$OUTPUT_NC"
echo "Next: source activate.sh && python3 scripts/make_video.py --size $VIZ_SIZE --variant $VIZ_VARIANT"
