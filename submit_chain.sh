#!/bin/bash
# submit_chain.sh — serialised submission controller with auto-resume.
#
# Tracks completed steps in results/completed_steps.txt. On a second
# invocation, already-completed steps are auto-skipped — you just
# re-run `bash submit_chain.sh` and it picks up where it left off.
#
# Cluster QOS (contest_v100):
#   - 1 Running job per user
#   - 2 nodes / 64 cores / 16 GPUs max
#   - 1 hour max per job
#   - QOSGrpJobsLimit: account-wide limit, can leave you pending indefinitely
#
# Usage:
#   bash submit_chain.sh              # run / resume from where it stopped
#   bash submit_chain.sh --force      # ignore completed_steps.txt and run all
#   bash submit_chain.sh --from N     # force-start from step index N
#   bash submit_chain.sh --status     # just print progress, don't submit
#
# If a job stays pending for too long due to account-wide QOS blocks
# (QOSGrpJobsLimit etc.), it is cancelled and the step is NOT marked
# completed — next invocation will retry it.

set -u
BASE="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$BASE"
mkdir -p logs results

[ -f "$BASE/config.sh" ] && source "$BASE/config.sh"

POLL_INTERVAL=60
PENDING_TIMEOUT_MIN=${PENDING_TIMEOUT_MIN:-30}
PNETCDF_DIR=${PNETCDF_DIR:-$BASE/external/pnetcdf_install}
COMPLETED_FILE=$BASE/results/completed_steps.txt
touch "$COMPLETED_FILE"

FORCE=0
START_IDX=0
STATUS_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force)        FORCE=1;                shift   ;;
    --from)         START_IDX=$2;           shift 2 ;;
    --status)       STATUS_ONLY=1;          shift   ;;
    --no-timeout)   PENDING_TIMEOUT_MIN=0;  shift   ;;
    --timeout)      PENDING_TIMEOUT_MIN=$2; shift 2 ;;
    -h|--help)
      sed -n '2,/^set -u/p' "$0" | head -25
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

JOBS=(
  "00_pnetcdf"
  "01_compile"
  "02_smoke"
  "check_correctness"
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
  "bench2n_easy_mpi"
  "bench2n_medium_mpi"
  "bench2n_medium_hybrid"
  "bench2n_hard_mpi"
  "bench2n_hard_hybrid"
)

# ----------------------------------------------------------------------

is_completed() {
  grep -Fxq "$1" "$COMPLETED_FILE" 2>/dev/null
}

mark_completed() {
  is_completed "$1" || echo "$1" >> "$COMPLETED_FILE"
}

# Some steps have product-based "skip" detection so users who didn't
# delete their builds can still resume after pulling a new repo etc.
products_exist() {
  case "$1" in
    00_pnetcdf)
      [ -f "$PNETCDF_DIR/lib/libpnetcdf.a" ] || [ -f "$PNETCDF_DIR/lib/libpnetcdf.so" ]
      ;;
    01_compile)
      [ -x "$BASE/builds/easy/serial" ]      && \
      [ -x "$BASE/builds/medium/serial" ]    && \
      [ -x "$BASE/builds/hard/serial" ]      && \
      [ -x "$BASE/builds/canonical/serial" ] && \
      [ -x "$BASE/builds/hard/mpi" ]
      ;;
    *) return 1 ;;
  esac
}

show_status() {
  echo "==== Progress ===="
  local done_count=0
  for s in "${JOBS[@]}"; do
    if is_completed "$s" || products_exist "$s"; then
      echo "  [DONE]    $s"
      done_count=$((done_count + 1))
    else
      echo "  [pending] $s"
    fi
  done
  echo
  echo "Total: $done_count / ${#JOBS[@]} completed"
}

if [ "$STATUS_ONLY" = "1" ]; then
  show_status
  exit 0
fi

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

# Returns:
#   0 = COMPLETED (success → mark completed)
#   1 = real failure (FAILED, TIMEOUT, NODE_FAIL, … → stop chain)
#   2 = TRANSIENT (QOS-blocked too long, CANCELLED → don't mark, leave for next run)
wait_for_job() {
  local jid=$1
  echo "  ($jid) polling every ${POLL_INTERVAL}s (pending-timeout=${PENDING_TIMEOUT_MIN}m)"

  local pending_start=0
  local was_pending=0

  while squeue -h -j "$jid" 2>/dev/null | grep -q .; do
    local line=$(squeue -h -j "$jid" -o "%t|%M|%R" 2>/dev/null | head -1)
    local state=$(echo "$line"   | cut -d'|' -f1)
    local elapsed=$(echo "$line" | cut -d'|' -f2)
    local reason=$(echo "$line"  | cut -d'|' -f3 | tr -d '()')

    echo "    [$jid] $state $elapsed $reason @ $(date +%T)"

    if [ "$state" = "PD" ]; then
      if [ "$was_pending" = "0" ]; then
        pending_start=$(date +%s)
        was_pending=1
      fi
      if [ "$PENDING_TIMEOUT_MIN" -gt 0 ]; then
        local pending_min=$(( ($(date +%s) - pending_start) / 60 ))
        case "$reason" in
          QOSGrpJobsLimit*|QOSGrpCpuLimit*|QOSGrpGresLimit*|QOSGrpNodeLimit*|QOSGrp*|ReqNodeNotAvail*|PartitionNodeLimit*|AssocGrpJobsLimit*)
            if [ "$pending_min" -ge "$PENDING_TIMEOUT_MIN" ]; then
              echo "    [$jid] pending ${pending_min}min due to '$reason'"
              echo "    [$jid] Cancelling. Will retry next time you run submit_chain.sh."
              scancel "$jid"
              sleep 5
              return 2
            fi
            ;;
        esac
      fi
    else
      was_pending=0
    fi
    sleep $POLL_INTERVAL
  done

  local final=""
  for _ in 1 2 3 4 5; do
    final=$(sacct -j "$jid" --noheader --format=State -P -X 2>/dev/null | head -1)
    [ -n "$final" ] && break
    sleep 5
  done
  echo "    [$jid] FINAL STATE: ${final:-UNKNOWN}"
  case "$final" in
    COMPLETED*) return 0 ;;
    CANCELLED*) return 2 ;;
    *)          return 1 ;;
  esac
}

# ----------------------------------------------------------------------

echo "================================================================"
echo "  miniWeather baseline chain   $(date)"
echo "  BASE = $BASE"
[ "$FORCE" = "1" ] && echo "  Mode: --force (ignoring completed_steps.txt)"
echo "  Pending timeout: ${PENDING_TIMEOUT_MIN} min (0 = disabled)"
echo "  Completed log: $COMPLETED_FILE"

# Show what's already done
if [ "$FORCE" = "0" ] && [ -s "$COMPLETED_FILE" ]; then
  done_n=$(wc -l < "$COMPLETED_FILE")
  echo "  Previously completed: $done_n step(s)"
fi
echo "================================================================"

wait_for_existing_jobs
echo "  No mw_* jobs in queue. Beginning."

n_completed=0
n_skipped=0
n_transient=0

for i in "${!JOBS[@]}"; do
  [ "$i" -lt "$START_IDX" ] && continue
  step="${JOBS[$i]}"

  # Resume logic: completed in a previous run → skip
  if [ "$FORCE" = "0" ] && is_completed "$step"; then
    echo
    echo "  [resume] STEP $i: $step — already completed; skipping"
    n_skipped=$((n_skipped + 1))
    continue
  fi

  echo
  echo "================================================================"
  echo "  STEP $i: $step    ($(date))"
  echo "================================================================"

  # Some steps can be skipped if their products are already there
  # (covers e.g. cloning a repo where pnetcdf/binaries pre-exist)
  if products_exist "$step"; then
    echo "  [skip] products already exist; marking as completed"
    mark_completed "$step"
    n_skipped=$((n_skipped + 1))
    continue
  fi

  sbatch_file="$BASE/slurm/${step}.sbatch"
  if [ ! -f "$sbatch_file" ]; then
    echo "  [warn] $sbatch_file not found, skipping"
    continue
  fi

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
    echo "  ERROR: sbatch repeatedly failed for $step"
    echo "  Re-run later:  bash submit_chain.sh"
    exit 3
  fi

  echo "  submitted: jobid=$jid"

  wait_for_job "$jid"
  rc=$?

  case $rc in
    0)
      mark_completed "$step"
      n_completed=$((n_completed + 1))
      ;;
    2)
      echo "  -> TRANSIENT (cancelled/QOS-blocked). NOT marked completed."
      echo "     Will retry when you next run submit_chain.sh."
      n_transient=$((n_transient + 1))
      ;;
    *)
      echo
      echo "  FAILURE: step $step (job $jid)"
      echo "  Inspect: logs/${step}_${jid}.log"
      echo "  Fix the issue then re-run:  bash submit_chain.sh"
      exit 4
      ;;
  esac
done

echo
echo "================================================================"
echo "  CHAIN PASS FINISHED  $(date)"
echo "================================================================"
echo "  Completed this pass:    $n_completed"
echo "  Skipped (already done): $n_skipped"
echo "  Transient (will retry): $n_transient"
echo
total_done=$(wc -l < "$COMPLETED_FILE" 2>/dev/null || echo 0)
echo "  Overall progress: $total_done / ${#JOBS[@]} steps"
if [ -f "$BASE/results/runs.csv" ]; then
  echo "  CSV rows: $(tail -n +2 $BASE/results/runs.csv | wc -l) total"
  echo "  Passed:   $(tail -n +2 $BASE/results/runs.csv | awk -F, '$15=="true"' | wc -l)"
fi

if [ "$n_transient" -gt 0 ] || [ "$total_done" -lt "${#JOBS[@]}" ]; then
  echo
  echo "  Not done yet. Re-run later to continue:"
  echo "    bash submit_chain.sh"
  echo "  See what's left:"
  echo "    bash submit_chain.sh --status"
else
  echo
  echo "  ALL STEPS DONE. Run:"
  echo "    source activate.sh && python3 scripts/analyze.py"
fi
