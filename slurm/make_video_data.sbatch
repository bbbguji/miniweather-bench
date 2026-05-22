#!/bin/bash
#SBATCH --account=ACD115053
#SBATCH --partition=nycugpu_queue
#SBATCH --job-name=mw_viz
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=1
#SBATCH --gpus-per-node=2
#SBATCH --time=0-00:25:00
#SBATCH -o logs/make_video_data_%j.log
#SBATCH -e logs/make_video_data_%j.err

# Build a visualization binary (with OUT_FREQ enabled) and run it to
# produce results/viz/output_<size>.nc. Benchmark binaries have
# OUT_FREQ=-1 so they cannot be reused for visualization.
#
# Usage:
#   sbatch slurm/make_video_data.sbatch              # default: easy
#   VIZ_SIZE=medium sbatch slurm/make_video_data.sbatch
#   VIZ_SIZE=hard   sbatch slurm/make_video_data.sbatch
#
# Custom parameters (override size preset):
#   VIZ_NX=1200 VIZ_NZ=600 VIZ_SIM_TIME=30 VIZ_OUT_FREQ=0.5 \
#       VIZ_SIZE=custom sbatch slurm/make_video_data.sbatch
#
# All env vars:
#   VIZ_SIZE       label used for output file + binary dir (default: easy)
#   VIZ_NX/NZ      grid size                              (default: from preset)
#   VIZ_SIM_TIME   simulation time in seconds             (default: from preset)
#   VIZ_OUT_FREQ   output frequency in sim-seconds        (default: from preset)
#   VIZ_RANKS      MPI ranks                              (default: 8)

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

# ---------- Size presets ----------
# Each preset chooses NX/NZ/SIM_TIME based on benchmark sizes,
# plus an OUT_FREQ that gives ~40 frames (visually smooth).
#
# Frame count = SIM_TIME / OUT_FREQ ≈ 40
# Storage    ≈ NX*NZ*4_vars*8_bytes*frames bytes
#   easy:   400×200×4×8×40 ≈   10 MB
#   medium: 800×400×4×8×40 ≈   40 MB
#   hard:  1600×800×4×8×24 ≈   97 MB
VIZ_SIZE=${VIZ_SIZE:-easy}

case "$VIZ_SIZE" in
  easy)
    : ${VIZ_NX:=400}    ; : ${VIZ_NZ:=200}
    : ${VIZ_SIM_TIME:=20} ; : ${VIZ_OUT_FREQ:=0.5}
    ;;
  medium)
    : ${VIZ_NX:=800}    ; : ${VIZ_NZ:=400}
    : ${VIZ_SIM_TIME:=20} ; : ${VIZ_OUT_FREQ:=0.5}
    ;;
  hard)
    : ${VIZ_NX:=1600}   ; : ${VIZ_NZ:=800}
    : ${VIZ_SIM_TIME:=12} ; : ${VIZ_OUT_FREQ:=0.5}
    ;;
  custom)
    # User must supply NX/NZ/SIM_TIME/OUT_FREQ in env
    for v in VIZ_NX VIZ_NZ VIZ_SIM_TIME VIZ_OUT_FREQ; do
      [ -z "${!v:-}" ] && { echo "ERROR: VIZ_SIZE=custom requires $v"; exit 1; }
    done
    ;;
  *)
    echo "ERROR: unknown VIZ_SIZE=$VIZ_SIZE (use: easy / medium / hard / custom)"
    exit 1
    ;;
esac

VIZ_RANKS=${VIZ_RANKS:-8}

# OpenMPI workaround
export OMPI_MCA_opal_cuda_support=0

VIZ_DIR=$BASE/builds/viz_$VIZ_SIZE
RUN_DIR=$BASE/results/viz
OUTPUT_NC=output_${VIZ_SIZE}.nc

echo "==== Visualization parameters ===="
echo "  VIZ_SIZE      = $VIZ_SIZE"
echo "  NX × NZ       = $VIZ_NX × $VIZ_NZ"
echo "  SIM_TIME      = $VIZ_SIM_TIME"
echo "  OUT_FREQ      = $VIZ_OUT_FREQ"
echo "  Expected frames ≈ $(echo "$VIZ_SIM_TIME / $VIZ_OUT_FREQ" | bc -l | awk '{printf "%.0f", $1}')"
echo "  VIZ_RANKS     = $VIZ_RANKS"
echo "  Output file   = $RUN_DIR/$OUTPUT_NC"

# ---------- Compile (skip if signature matches) ----------
SIG="${VIZ_NX}_${VIZ_NZ}_${VIZ_SIM_TIME}_${VIZ_OUT_FREQ}"
SIG_FILE=$VIZ_DIR/.sig

need_compile=1
if [ -f "$SIG_FILE" ] && [ -x "$VIZ_DIR/mpi" ]; then
  cached=$(cat "$SIG_FILE")
  [ "$cached" = "$SIG" ] && need_compile=0
fi

if [ "$need_compile" = "1" ]; then
  echo
  echo "==== Compiling viz binary for size=$VIZ_SIZE ===="
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
  echo "==== Viz binary already compiled (signature match: $SIG) ===="
fi

# ---------- Run ----------
mkdir -p "$RUN_DIR"
cd "$RUN_DIR"
rm -f output.nc "$OUTPUT_NC"

echo
echo "==== Running (ranks=$VIZ_RANKS) in $RUN_DIR ===="
srun --mpi=pmix --ntasks=$VIZ_RANKS --cpus-per-task=1 --cpu-bind=cores \
     "$VIZ_DIR/mpi"

# miniWeather always writes to "output.nc" — rename per-size
[ -f output.nc ] || { echo "ERROR: output.nc not produced"; exit 1; }
mv output.nc "$OUTPUT_NC"

echo
echo "==== Result ===="
ls -lh "$OUTPUT_NC"
echo
echo "Next: from a login-node shell run"
echo "  source activate.sh"
echo "  python3 scripts/make_video.py --size $VIZ_SIZE"
