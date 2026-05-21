#!/bin/bash
# One-time setup. Run on LOGIN NODE from this repo's root directory.
#
#   git clone <repo-url> /work/$USER/miniWeather-bench
#   cd /work/$USER/miniWeather-bench
#   bash setup.sh
set -e

# BASE = directory of this script (the repo root)
BASE="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
echo "==== Setup at: $BASE ===="

mkdir -p "$BASE"/{slurm,scripts,builds,logs,results,external}

# Load defaults (account/partition, etc.)
[ -f "$BASE/config.sh" ] && source "$BASE/config.sh"

echo
echo "==== Clone miniWeather source ===="
cd "$BASE"
if [ ! -d miniWeather ]; then
  git clone https://github.com/mrnorman/miniWeather.git
else
  echo "  (already cloned)"
fi

echo
echo "==== Check pnetcdf ===="
PNETCDF_DIR=${PNETCDF_DIR:-$BASE/external/pnetcdf_install}
if [ -f "$PNETCDF_DIR/lib/libpnetcdf.a" ] || [ -f "$PNETCDF_DIR/lib/libpnetcdf.so" ]; then
  echo "  [OK] pnetcdf at $PNETCDF_DIR"
else
  echo "  [MISSING] pnetcdf not built yet."
  echo "  Build it with:  sbatch slurm/00_pnetcdf.sbatch"
fi

echo
echo "==== Setup done ===="
echo
echo "Next steps:"
echo "  sbatch slurm/00_pnetcdf.sbatch    # if pnetcdf missing (~10 min)"
echo "  sbatch slurm/01_compile.sbatch    # build binaries (~5 min)"
echo "  sbatch slurm/02_smoke.sbatch      # sanity check (~3 min)"
echo "  bash submit_chain.sh              # full sweep (~3-6 hours)"
echo "  sbatch slurm/bench_medium_openmp.sbatch   # or any single benchmark"
