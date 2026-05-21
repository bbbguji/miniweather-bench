#!/bin/bash
# Sets up a Python virtualenv with pandas/numpy/matplotlib for analyze.py.
# Run once on the login node after setup.sh.
#
# Usage:
#   bash setup_python.sh
#
# Then to use:
#   source venv/bin/activate
#   python3 scripts/analyze.py
set -e

BASE="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$BASE"

echo "==== Python venv setup ===="

# Find a usable system python
PY=""
for cand in python3 python3.9 python3.10 python3.11 python3.8; do
  if command -v $cand >/dev/null 2>&1; then
    PY=$cand
    break
  fi
done
[ -n "$PY" ] || { echo "ERROR: no python3 found"; exit 1; }
echo "Using interpreter: $(command -v $PY) ($(${PY} --version 2>&1))"

# Create venv
if [ ! -d venv ]; then
  $PY -m venv venv
  echo "Created venv/"
else
  echo "venv/ already exists, will upgrade packages"
fi

# Activate and install
source venv/bin/activate
python -m pip install --upgrade pip --quiet
python -m pip install --quiet \
  pandas \
  numpy \
  matplotlib

echo
echo "==== Installed ===="
python -c "import pandas, numpy, matplotlib; \
  print('pandas:', pandas.__version__); \
  print('numpy: ', numpy.__version__); \
  print('matplotlib:', matplotlib.__version__)"

echo
echo "==== Done ===="
echo "Activate later with:  source venv/bin/activate"
echo "Run analyze with:     python3 scripts/analyze.py"
