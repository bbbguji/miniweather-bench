# config.sh — edit if your cluster/account differs.
# Sourced by sbatch scripts (after #SBATCH directives) and helpers.

# SLURM account (passed via `sbatch -A ...` if set here)
export ACCOUNT=${ACCOUNT:-ACD115053}

# SLURM partition (passed via `sbatch -p ...` if set here)
export PARTITION=${PARTITION:-nycugpu_queue}

# (Optional) override default thread/rank sweep — defaults defined in bench files.
# E.g. NREPS=3 to do fewer repetitions:
# export NREPS=5

# (Optional) override pnetcdf install location (default: $BASE/external/pnetcdf_install)
# export PNETCDF_DIR=/some/other/path
