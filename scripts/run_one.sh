#!/bin/bash
# Common run helpers. SOURCED by sbatch scripts after they set BASE & RESULTS.

# OpenMPI 5 workaround
export OMPI_MCA_opal_cuda_support=0

# Force pmix for OpenMPI 5; default pmi2 launches in singleton mode
SRUN_MPI=--mpi=pmix

init_results_csv() {
  mkdir -p "$(dirname $RESULTS)"
  mkdir -p "$BASE/logs/runs"
  if [ ! -f "$RESULTS" ]; then
    echo "timestamp,variant,size,nx,nz,sim_time,nodes,ranks,threads_per_rank,total_cores,run_id,wall_time_s,d_mass,d_te,passed,raw_log" > "$RESULTS"
    echo "Initialized $RESULTS"
  fi
}

# All three benchmark sizes use the same sim_time=20 so wall-time scales
# purely with NX² × NZ. Calibrated serial-time predictions on this cluster:
#   easy   (1000× 500) ~ 1.3 min
#   medium (1600× 800) ~ 5.3 min
#   hard   (2000×1000) ~ 10.3 min
#   canonical (200×100, sim_time=400) — only for upstream strict check
get_size_params() {
  case "$1" in
    easy)      echo "1000  500 20"  ;;
    medium)    echo "1600  800 20"  ;;
    hard)      echo "2000 1000 20"  ;;
    canonical) echo " 200  100 400" ;;
    *)         echo ""; return 1    ;;
  esac
}

# Cores must be in {1,2,4,8,16,32,64} (cluster QOS = 64 max)
_assert_cores_ok() {
  case "$1" in
    1|2|4|8|16|32|64) return 0 ;;
    *) echo "  [error] cores=$1 not in {1,2,4,8,16,32,64}"; return 1 ;;
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

  # Singleton-mode detector for MPI
  if [[ "$variant" =~ ^mpi ]] && [ "$ranks" -gt 1 ] && [ -f "$raw_log" ]; then
    local nx_count=$(grep -c "nx_glob" "$raw_log" 2>/dev/null | tr -d '[:space:]')
    nx_count=${nx_count:-0}
    if [[ "$nx_count" =~ ^[0-9]+$ ]] && [ "$nx_count" -gt 1 ]; then
      echo "    !! WARNING: $nx_count nx_glob lines - MPI ranks in SINGLETON mode."
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
  local out=$(srun $SRUN_MPI --nodes=1 --ntasks=1 --cpus-per-task=1 --cpu-bind=cores "$exe" 2>&1)
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
  local out=$(srun $SRUN_MPI --nodes=1 --ntasks=1 --cpus-per-task=$threads --cpu-bind=cores "$exe" 2>&1)
  parse_and_log "$out" openmp $size $nx $nz $st 1 1 $threads $threads $rep
}

run_mpi() {
  local size=$1 ranks=$2 rep=$3 nodes=${4:-1}
  _assert_cores_ok $ranks || return
  read nx nz st <<< $(get_size_params $size)
  local exe=$BASE/builds/$size/mpi
  [ -x "$exe" ] || { echo "  [skip] missing $exe"; return; }
  local label="mpi"
  [ $nodes -gt 1 ] && label="mpi_${nodes}node"
  echo "[$label / $size / ${ranks}R on ${nodes}N / rep $rep]"
  unset OMP_NUM_THREADS
  local rpn=$((ranks / nodes))
  local out=$(srun $SRUN_MPI --nodes=$nodes --ntasks=$ranks --ntasks-per-node=$rpn \
                 --cpus-per-task=1 --cpu-bind=cores "$exe" 2>&1)
  parse_and_log "$out" $label $size $nx $nz $st $nodes $ranks 1 $ranks $rep
}

run_hybrid() {
  local size=$1 ranks=$2 threads=$3 rep=$4 nodes=${5:-1}
  local total=$((ranks * threads))
  _assert_cores_ok $total || return
  read nx nz st <<< $(get_size_params $size)
  local exe=$BASE/builds/$size/openmp
  [ -x "$exe" ] || { echo "  [skip] missing $exe"; return; }
  local label="hybrid"
  [ $nodes -gt 1 ] && label="hybrid_${nodes}node"
  echo "[$label / $size / ${ranks}R x ${threads}T on ${nodes}N / rep $rep]"
  export OMP_NUM_THREADS=$threads OMP_PLACES=cores OMP_PROC_BIND=close
  local rpn=$((ranks / nodes))
  local out=$(srun $SRUN_MPI --nodes=$nodes --ntasks=$ranks --ntasks-per-node=$rpn \
                 --cpus-per-task=$threads --cpu-bind=cores "$exe" 2>&1)
  parse_and_log "$out" $label $size $nx $nz $st $nodes $ranks $threads $total $rep
}
