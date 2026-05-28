#!/bin/bash
#SBATCH --account=ACD115053
#SBATCH --partition=nycugpu_queue
#SBATCH --job-name=mw_viz
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=32
#SBATCH --cpus-per-task=1
#SBATCH --gpus-per-node=8
#SBATCH --time=0-00:55:00
#SBATCH -o logs/make_video_data_%j.log
#SBATCH -e logs/make_video_data_%j.err

# Build a viz binary (with OUT_FREQ enabled) and run it to produce
# results/viz/output_<size>.nc. Benchmark binaries have OUT_FREQ=-1
# so cannot be reused for visualization.
#
# Usage:
#   sbatch slurm/make_video_data.sbatch              # default: easy
#   VIZ_SIZE=medium sbatch slurm/make_video_data.sbatch
#   VIZ_SIZE=hard   sbatch slurm/make_video_data.sbatch
#
# Env overrides:
#   VIZ_SIZE       label                       (default: easy)
#   VIZ_NX/NZ      grid (default from preset)
#   VIZ_SIM_TIME   sim seconds (default 20)
#   VIZ_OUT_FREQ   output freq in sim-sec (default: pick ~40 frames)
#   VIZ_RANKS      MPI ranks                   (default: 32)

set -e
module purge
module load gcc10/10.2.1
module load openmpi/5.0.2_ucx1.14.1_cuda12.3
module load cmake 2>/dev/null || module load cmake3 2>/dev/null || {
  echo "ERROR: no cmake module"; exit 1; }

BASE=${BASE:-$SLURM_SUBMIT_DIR}
[ -n "$BASE" ] && [ -d "$BASE" ] || { echo "ERROR: BASE invalid"; exit 1; }
[ -f "$BASE/config.sh" ] && source "$BASE/config.sh"

PNETCDF_DIR=${PNETCDF_DIR:-$BASE/external/pnetcdf_install}
SRC=$BASE/miniWeather/c

VIZ_SIZE=${VIZ_SIZE:-easy}
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
    echo "ERROR: unknown VIZ_SIZE=$VIZ_SIZE (use: easy/medium/hard/custom)"
    exit 1
    ;;
esac

VIZ_RANKS=${VIZ_RANKS:-32}
export OMPI_MCA_opal_cuda_support=0

VIZ_DIR=$BASE/builds/viz_$VIZ_SIZE
RUN_DIR=$BASE/results/viz
OUTPUT_NC=output_${VIZ_SIZE}.nc

echo "==== Viz params (size=$VIZ_SIZE) ===="
echo "  NX × NZ       = $VIZ_NX × $VIZ_NZ"
echo "  SIM_TIME      = $VIZ_SIM_TIME"
echo "  OUT_FREQ      = $VIZ_OUT_FREQ"
echo "  Frames ≈ $(echo "$VIZ_SIM_TIME / $VIZ_OUT_FREQ" | bc -l | awk '{printf "%.0f", $1}')"
echo "  VIZ_RANKS     = $VIZ_RANKS"
echo "  Output        = $RUN_DIR/$OUTPUT_NC"

# Compile if signature changed
SIG="${VIZ_NX}_${VIZ_NZ}_${VIZ_SIM_TIME}_${VIZ_OUT_FREQ}"
SIG_FILE=$VIZ_DIR/.sig
need_compile=1
if [ -f "$SIG_FILE" ] && [ -x "$VIZ_DIR/mpi" ]; then
  cached=$(cat "$SIG_FILE")
  [ "$cached" = "$SIG" ] && need_compile=0
fi

if [ "$need_compile" = "1" ]; then
  echo
  echo "==== Compiling viz binary for $VIZ_SIZE ===="
  rm -rf "$VIZ_DIR"
  mkdir -p "$VIZ_DIR"
  cd "$VIZ_DIR"
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
  make -j 8 mpi > make.log 2>&1 || { tail -30 make.log; exit 1; }
  [ -x "$VIZ_DIR/mpi" ] || { echo "ERROR: viz binary not produced"; exit 1; }
  echo "$SIG" > "$SIG_FILE"
  echo "  [OK]   $VIZ_DIR/mpi"
else
  echo "==== Viz binary already compiled (sig=$SIG) ===="
fi

mkdir -p "$RUN_DIR"
cd "$RUN_DIR"
rm -f output.nc "$OUTPUT_NC"

echo
echo "==== Running (ranks=$VIZ_RANKS) in $RUN_DIR ===="
srun --mpi=pmix --ntasks=$VIZ_RANKS --cpus-per-task=1 --cpu-bind=cores "$VIZ_DIR/mpi"

[ -f output.nc ] || { echo "ERROR: output.nc not produced"; exit 1; }
mv output.nc "$OUTPUT_NC"

echo
echo "==== Result ===="
ls -lh "$OUTPUT_NC"
echo "Next: source activate.sh && python3 scripts/make_video.py --size $VIZ_SIZE"
