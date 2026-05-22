#!/bin/bash
# Sets up a conda environment with packages for analyze.py + make_video.py.
#
# Why conda env (not venv): cluster's system python is 3.6 (EOL) and
# `python -m venv` would inherit that. Loading `miniforge/24.7.1-2` puts
# conda on PATH but doesn't change `python3` itself — we have to ask
# conda to *create* a new env with a newer Python.
#
# Usage:
#   bash setup_python.sh
#
# Then in every shell:
#   source activate.sh

set -e

BASE="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$BASE"

ENV_NAME=${ENV_NAME:-mw}
ENV_PATH=$BASE/conda_env
PY_VER=${PY_VER:-3.11}

echo "==== Loading conda module ===="

loaded=""
for mod in miniforge/24.7.1-2 miniconda3/conda24.5.0_py3.9; do
  if module load "$mod" 2>/dev/null; then
    loaded="$mod"
    echo "  Loaded: $mod"
    break
  fi
done
[ -n "$loaded" ] || { echo "ERROR: no conda module"; exit 1; }

# `conda` should now be on PATH
command -v conda >/dev/null || { echo "ERROR: conda not in PATH"; exit 1; }
echo "  conda: $(command -v conda)"

# Initialize conda for this shell session (needed for `conda activate`)
# This evaluates conda's hook script - cleaner than `eval "$(conda shell.bash hook)"`
# because the module already set CONDA_EXE
source "$(conda info --base)/etc/profile.d/conda.sh"

echo
echo "==== Creating/updating env at $ENV_PATH ===="
if [ -d "$ENV_PATH" ]; then
  echo "  $ENV_PATH already exists; updating packages"
else
  conda create --prefix "$ENV_PATH" --yes \
    --channel conda-forge --override-channels \
    "python=$PY_VER"
  echo "  Created env at $ENV_PATH"
fi

# Activate the env
conda activate "$ENV_PATH"

ver=$(python -c "import sys; print('{}.{}'.format(*sys.version_info[:2]))")
echo "  Python: $(command -v python) ($ver)"

echo
echo "==== Installing packages ===="
# conda-forge has prebuilt netCDF4 with HDF5 — no source compile needed
conda install --prefix "$ENV_PATH" --yes --quiet \
  --channel conda-forge --override-channels \
  pandas \
  numpy \
  matplotlib \
  netcdf4 \
  imageio-ffmpeg

echo
echo "==== Verifying ===="
python <<'PY_EOF'
import sys
print(f"python: {sys.version.split()[0]}")
mods = ["pandas", "numpy", "matplotlib", "netCDF4", "imageio_ffmpeg"]
ok = True
for m in mods:
    try:
        mod = __import__(m)
        v = getattr(mod, "__version__", "?")
        print(f"  {m:18s} {v}")
    except Exception as e:
        print(f"  {m:18s} FAIL: {e}")
        ok = False
if not ok:
    sys.exit(1)
import imageio_ffmpeg
print(f"  ffmpeg:           {imageio_ffmpeg.get_ffmpeg_exe()}")
PY_EOF

echo
echo "==== Done ===="
echo
echo "Use in every new shell:"
echo "  source activate.sh"
echo
echo "Then run:"
echo "  python3 scripts/analyze.py"
echo "  python3 scripts/make_video.py"
