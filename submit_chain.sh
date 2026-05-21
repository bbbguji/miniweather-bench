#!/bin/bash
# submit_chain.sh — serialised submission controller.
#
# QOS constraints (Taiwania 2 / contest_v100):
#   - 1 mw_* job in queue at a time
#   - 25 min max per job
#   - 8 CPUs / 2 GPUs / 1 node per job
#
# Usage:
#   bash submit_chain.sh             # full chain in order
#   bash submit_chain.sh --from N    # start from step index N
#
# Run inside tmux for SSH-survival:
#   tmux new -s mw
#   bash submit_chain.sh
#   # detach: Ctrl-b d ;  reattach: tmux attach -t mw

set -u
# Auto-detect repo root
BASE="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$BASE"
mkdir -p logs results

[ -f "$BASE/config.sh" ] && source "$BASE/config.sh"

POLL_INTERVAL=60
PNETCDF_DIR=${PNETCDF_DIR:-$BASE/external/pnetcdf_install}

JOBS=(
  "00_pnetcdf"
  "01_compile"
  "02_smoke"
  "bench_easy_serial"
  "bench_easy_openmp"
  "bench_easy_mpi"
  "bench_easy_hybrid"
  "bench_medium_serial"
  "bench_medium_openmp"
  "bench_medium_mpi"
  "bench_medium_hybrid"
  "bench_hard_serial"
  "bench_hard_openmp"
  "bench_hard_mpi"
  "bench_hard_hybrid"
)

can_skip_step() {
  case "$1" in
    00_pnetcdf)
      [ -f "$PNETCDF_DIR/lib/libpnetcdf.a" ] || [ -f "$PNETCDF_DIR/lib/libpnetcdf.so" ]
      ;;
    01_compile)
      [ -x "$BASE/builds/easy/serial" ]   && \
      [ -x "$BASE/builds/medium/serial" ] && \
      [ -x "$BASE/builds/hard/mpi" ]
      ;;
    *) return 1 ;;
  esac
}

wait_for_existing_jobs() {
  while true; do
    local n
    n=$(squeue -h -u "$USER" -o "%j" 2>/dev/null | grep -c "^mw_" || true)
    [ "$n" -eq 0 ] && return
    echo "  [$(date +%T)] $n existing mw_* job(s):"
    squeue -u "$USER" -o "%.10i %.12j %.2t %.10M %R"
    sleep $POLL_INTERVAL
  done
}

wait_for_job() {
  local jid=$1
  echo "  ($jid) polling every ${POLL_INTERVAL}s..."
  while squeue -h -j "$jid" 2>/dev/null | grep -q .; do
    local s=$(squeue -h -j "$jid" -o "%.2t %.10M %R" 2>/dev/null | head -1)
    echo "    [$jid] $s @ $(date +%T)"
    sleep $POLL_INTERVAL
  done
  local final=""
  for _ in 1 2 3 4 5; do
    final=$(sacct -j "$jid" --noheader --format=State -P -X 2>/dev/null | head -1)
    [ -n "$final" ] && break
    sleep 5
  done
  echo "    [$jid] FINAL STATE: ${final:-UNKNOWN}"
  case "$final" in COMPLETED*) return 0 ;; *) return 1 ;; esac
}

START_IDX=0
if [ "${1:-}" = "--from" ] && [ -n "${2:-}" ]; then
  START_IDX=$2
fi

echo "================================================================"
echo "  miniWeather baseline chain   $(date)"
echo "  BASE = $BASE"
echo "  Starting from index $START_IDX"
echo "================================================================"
wait_for_existing_jobs
echo "  No mw_* jobs in queue. Beginning."

for i in "${!JOBS[@]}"; do
  [ "$i" -lt "$START_IDX" ] && continue
  step="${JOBS[$i]}"
  echo
  echo "================================================================"
  echo "  STEP $i: $step    ($(date))"
  echo "================================================================"

  if can_skip_step "$step"; then
    echo "  [skip] products already exist"
    continue
  fi

  sbatch_file="$BASE/slurm/${step}.sbatch"
  [ -f "$sbatch_file" ] || { echo "  [skip] $sbatch_file not found"; continue; }

  jid=""
  for attempt in 1 2 3; do
    raw=$(sbatch --parsable "$sbatch_file" 2>&1)
    jid=$(echo "$raw" | grep -oE '^[0-9]+' | head -1)
    if [ -n "$jid" ]; then
      warn=$(echo "$raw" | grep -E '^sbatch:' || true)
      [ -n "$warn" ] && echo "  (warnings: $warn)"
      break
    fi
    echo "  sbatch attempt $attempt failed: $raw"
    sleep $POLL_INTERVAL
    jid=""
  done

  if [ -z "$jid" ]; then
    echo "  ERROR: sbatch repeatedly failed for $step (index $i)"
    echo "  Resume:  bash submit_chain.sh --from $i"
    exit 3
  fi

  echo "  submitted: jobid=$jid"

  if ! wait_for_job "$jid"; then
    echo
    echo "  FAILURE: step $step (job $jid)"
    echo "  Inspect: logs/${step}_${jid}.log"
    echo "  Resume:  bash submit_chain.sh --from $i"
    exit 4
  fi
done

echo
echo "================================================================"
echo "  ALL JOBS COMPLETE  $(date)"
echo "================================================================"
if [ -f "$BASE/results/runs.csv" ]; then
  echo "  Total rows: $(tail -n +2 $BASE/results/runs.csv | wc -l)"
  echo "  Passed:     $(tail -n +2 $BASE/results/runs.csv | awk -F, '$15=="true"' | wc -l)"
fi
echo "Next: python3 scripts/analyze.py"
