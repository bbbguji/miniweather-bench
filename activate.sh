# Source this file to enter the analysis environment in any new shell:
#   source activate.sh
#
# (Do NOT `bash activate.sh` — that runs in a subshell and won't affect
# your current shell's PATH / environment.)

# Load conda module
module load miniforge/24.7.1-2 2>/dev/null || \
  module load miniconda3/conda24.5.0_py3.9 2>/dev/null || {
    echo "ERROR: no conda module available"
    return 1 2>/dev/null || exit 1
  }

# Resolve repo root (the dir this script lives in)
_BASE="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
_ENV="$_BASE/conda_env"

if [ ! -d "$_ENV" ]; then
  echo "Env $_ENV missing. Run: bash setup_python.sh"
  return 1 2>/dev/null || exit 1
fi

# Initialize conda hook in this shell
source "$(conda info --base)/etc/profile.d/conda.sh"
conda activate "$_ENV"

echo "Environment ready. Python: $(python3 --version 2>&1)"
unset _BASE _ENV
