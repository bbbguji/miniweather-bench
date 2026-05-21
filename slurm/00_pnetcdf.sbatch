#!/bin/bash
#SBATCH --account=ACD115053
#SBATCH --partition=nycugpu_queue
#SBATCH --job-name=mw_pnetcdf
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=8
#SBATCH --gpus-per-node=2
#SBATCH --time=0-00:25:00
#SBATCH -o logs/00_pnetcdf_%j.log
#SBATCH -e logs/00_pnetcdf_%j.err

# One-time PnetCDF build. Installs into $BASE/external/pnetcdf_install/.
# Override defaults by editing config.sh or passing env vars:
#   PNETCDF_VERSION=1.13.0  sbatch slurm/00_pnetcdf.sbatch

set -e
module purge
module load gcc10/10.2.1
module load openmpi/5.0.2_ucx1.14.1_cuda12.3

# Auto-detect repo root (the directory you ran `sbatch` from)
BASE=${BASE:-$SLURM_SUBMIT_DIR}
[ -n "$BASE" ] || { echo "ERROR: BASE not set and SLURM_SUBMIT_DIR empty"; exit 1; }
[ -d "$BASE" ] || { echo "ERROR: BASE=$BASE not a directory"; exit 1; }
[ -f "$BASE/config.sh" ] && source "$BASE/config.sh"

PNETCDF_VERSION=${PNETCDF_VERSION:-1.13.0}
PNETCDF_DIR=${PNETCDF_DIR:-$BASE/external/pnetcdf_install}
EXTERNAL=$BASE/external

mkdir -p "$EXTERNAL" "$PNETCDF_DIR"
cd "$EXTERNAL"

echo "==== PnetCDF $PNETCDF_VERSION build ===="
echo "  Install prefix: $PNETCDF_DIR"

if [ ! -d "pnetcdf-$PNETCDF_VERSION" ]; then
  wget -q "https://parallel-netcdf.github.io/Release/pnetcdf-$PNETCDF_VERSION.tar.gz"
  tar -xzf "pnetcdf-$PNETCDF_VERSION.tar.gz"
fi

cd "pnetcdf-$PNETCDF_VERSION"

./configure --prefix="$PNETCDF_DIR" \
            MPICC=mpicc \
            MPICXX=mpic++ \
            MPIF77=mpif77 \
            MPIF90=mpif90

make -j 8
make install

echo "==== PnetCDF Done ===="
ls -lh "$PNETCDF_DIR/lib/libpnetcdf"* || { echo "ERROR: libpnetcdf not produced"; exit 1; }
