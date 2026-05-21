#!/bin/bash
# Common run helpers. SOURCED by sbatch scripts after they set BASE & RESULTS.

# OpenMPI 5 workaround: cluster sets cuda_support=1 but lib lacks CUDA.
export OMPI_MCA_opal_cuda_support=0

# OpenMPI 5 on Taiwania 2's Slurm needs explicit pmix (default pmi2 causes
# silent fallback to singleton mode - each rank thinks it's rank 0).
SRUN_MPI=--mpi=pmix

init_results_csv() {
  mkdir -p "$(dirname $RESULTS)"
  mkdir -p "$BASE/logs/runs"
  if [ ! -f "$RESULTS" ]; then
    echo "timestamp,variant,size,nx,nz,sim_time,nodes,ranks,threads_per_rank,total_cores,run_id,wall_time_s,d_mass,d_te,passed,raw_log" > "$RESULTS"
    echo "Initialized $RESULTS"
  fi
}

get_size_params() {
  case "$1" in
    easy)   echo "400  200  20" ;;
    medium) echo "800  400  20" ;;
    hard)   echo "1600 800  12" ;;
    canonical) echo "200  100  400" ;;
    *)      echo ""; return 1   ;;
  esac
}

_assert_cores_ok() {
  case "$1" in
    1|2|4|8) return 0 ;;
    *) echo "  [error] cores=$1 exceeds QOS limit of 8"; return 1 ;;
  esac
}

parse_and_log() {
  local output="$1"
  local variant="$2" size="$3" nx="$4" nz="$5" st="$6"
  local nodes="$7" ranks="$8" threads="$9" total="${10}" rid="${11}"

  local tag="${variant}_${size}_n${nodes}_r${ranks}_t${threads}_rep${rid}"
  local raw_log="$BASE/logs/runs/${tag}.out"
  echo "$output" > "$raw_log"

  local wall=$(echo "$output"  | grep "CPU Time:" | head -1 | grep -oE '[0-9]+\.[0-9]+([eE][+-]?[0-9]+)?' | head -1)
  local dmass=$(echo "$output" | grep "d_mass:"   | head -1 | grep -oE '[+-]?[0-9]+\.[0-9]+([eE][+-]?[0-9]+)?' | head -1)
  local dte=$(echo "$output"   | grep "d_te:"     | head -1 | grep -oE '[+-]?[0-9]+\.[0-9]+([eE][+-]?[0-9]+)?' | head -1)
  wall=${wall:-NaN}; dmass=${dmass:-NaN}; dte=${dte:-NaN}

  if [ "$wall" = "NaN" ] || [ "$dmass" = "NaN" ] || [ "$dte" = "NaN" ]; then
    echo "    !! PARSE FAILED. Last 20 lines of $raw_log:"
    echo "    ------ BEGIN RAW ------"
    tail -20 "$raw_log" | sed 's/^/    | /'
    echo "    ------ END RAW   ------"
  fi

  # Singleton-mode detector. Robust against grep -c quirks:
  # use grep | wc -l rather than grep -c, and sanitise whitespace.
  if [ "$variant" = "mpi" ] && [ "$ranks" -gt 1 ] && [ -f "$raw_log" ]; then
    local nx_count
    nx_count=$(grep -c "nx_glob" "$raw_log" 2>/dev/null | tr -d '[:space:]')
    nx_count=${nx_count:-0}
    if [[ "$nx_count" =~ ^[0-9]+$ ]] && [ "$nx_count" -gt 1 ]; then
      echo "    !! WARNING: $nx_count nx_glob lines - MPI ranks in SINGLETON mode."
      echo "    !! Check srun --mpi=pmix is being used."
    fi
  fi

  local passed="false"
  if [[ "$dmass" != "NaN" && "$dte" != "NaN" ]]; then
    passed=$(python3 -c "
try:
    m = abs(float('$dmass')) < 1e-8
    e = float('$dte')
    print('true' if (m and (e < 1e-8) and (abs(e) < 1e-2)) else 'false')
except Exception:
    print('false')
" 2>/dev/null)
    passed=${passed:-false}
  fi

  local ts=$(date -Iseconds)
  echo "$ts,$variant,$size,$nx,$nz,$st,$nodes,$ranks,$threads,$total,$rid,$wall,$dmass,$dte,$passed,$raw_log" >> "$RESULTS"
  echo "    -> wall=$wall s | dmass=$dmass | dte=$dte | passed=$passed"
}

run_serial() {
  local size=$1 rep=$2
  read nx nz st <<< $(get_size_params $size)
  local exe=$BASE/builds/$size/serial
  [ -x "$exe" ] || { echo "  [skip] missing $exe"; return; }
  echo "[serial / $size / rep $rep]"
  unset OMP_NUM_THREADS
  local out=$(srun $SRUN_MPI --ntasks=1 --cpus-per-task=1 --cpu-bind=cores "$exe" 2>&1)
  parse_and_log "$out" serial $size $nx $nz $st 1 1 1 1 $rep
}

run_openmp() {
  local size=$1 threads=$2 rep=$3
  _assert_cores_ok $threads || return
  read nx nz st <<< $(get_size_params $size)
  local exe=$BASE/builds/$size/openmp
  [ -x "$exe" ] || { echo "  [skip] missing $exe"; return; }
  echo "[openmp / $size / ${threads}T / rep $rep]"
  export OMP_NUM_THREADS=$threads OMP_PLACES=cores OMP_PROC_BIND=close
  local out=$(srun $SRUN_MPI --ntasks=1 --cpus-per-task=$threads --cpu-bind=cores "$exe" 2>&1)
  parse_and_log "$out" openmp $size $nx $nz $st 1 1 $threads $threads $rep
}

run_mpi() {
  local size=$1 ranks=$2 rep=$3
  _assert_cores_ok $ranks || return
  read nx nz st <<< $(get_size_params $size)
  local exe=$BASE/builds/$size/mpi
  [ -x "$exe" ] || { echo "  [skip] missing $exe"; return; }
  echo "[mpi / $size / ${ranks}R / rep $rep]"
  unset OMP_NUM_THREADS
  local out=$(srun $SRUN_MPI --ntasks=$ranks --cpus-per-task=1 --cpu-bind=cores "$exe" 2>&1)
  parse_and_log "$out" mpi $size $nx $nz $st 1 $ranks 1 $ranks $rep
}

run_hybrid() {
  local size=$1 ranks=$2 threads=$3 rep=$4
  local total=$((ranks * threads))
  _assert_cores_ok $total || return
  read nx nz st <<< $(get_size_params $size)
  local exe=$BASE/builds/$size/openmp
  [ -x "$exe" ] || { echo "  [skip] missing $exe"; return; }
  echo "[hybrid / $size / ${ranks}R x ${threads}T / rep $rep]"
  export OMP_NUM_THREADS=$threads OMP_PLACES=cores OMP_PROC_BIND=close
  local out=$(srun $SRUN_MPI --ntasks=$ranks --cpus-per-task=$threads --cpu-bind=cores "$exe" 2>&1)
  parse_and_log "$out" hybrid $size $nx $nz $st 1 $ranks $threads $total $rep
}
