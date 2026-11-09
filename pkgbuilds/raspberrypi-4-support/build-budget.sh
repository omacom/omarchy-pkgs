# shellcheck shell=bash
# Source before an explicit workload. These are compiler hints, not an
# aggregate memory cap; omarchy-pi-run supplies the systemd scope limits.
# Never add -march=native: artifacts must run on the supported Pi 4 boards.
omarchy_pi_build_budget() {
  local cores available total jobs memory_jobs value flag previous="" make_jobs
  local xz_memory="25%" xz_memory_kib memory_value memory_unit candidate_kib
  local -a make_flags=() xz_flags=()
  cores=$(nproc) || return 1
  available=$(awk '/^MemAvailable:/ {print $2}' "${OMARCHY_PI_MEMINFO:-/proc/meminfo}") || return 1
  total=$(awk '/^MemTotal:/ {print $2}' "${OMARCHY_PI_MEMINFO:-/proc/meminfo}") || return 1
  if [[ ! $cores =~ ^[1-9][0-9]*$ || ! $available =~ ^[0-9]+$ || ! $total =~ ^[1-9][0-9]*$ ]]; then
    echo "Cannot determine the Pi build CPU/RAM budget." >&2
    return 1
  fi
  jobs=$(( cores > 1 ? cores - 1 : 1 ))
  memory_jobs=$(( 10#$available / 1048576 ))
  (( memory_jobs > 0 )) || memory_jobs=1
  (( jobs <= memory_jobs )) || jobs=$memory_jobs
  if (( total < 5242880 )); then
    (( jobs <= 2 )) || jobs=2
  else
    (( jobs <= 3 )) || jobs=3
  fi
  export OMARCHY_PI_BUILD_JOBS=$jobs

  # Retain unrelated Make flags and any tighter explicit job limit. Last -j
  # wins in GNU make, including when the caller supplied an unbounded -j.
  make_jobs=$jobs
  read -r -a make_flags <<<"${MAKEFLAGS:-}"
  for flag in "${make_flags[@]}"; do
    value=""
    if [[ $previous == "-j" || $previous == "--jobs" ]]; then
      [[ ! $flag =~ ^[0-9]+$ ]] || value=$flag
    elif [[ $flag =~ ^-j([0-9]+)$ || $flag =~ ^--jobs=([0-9]+)$ ]]; then
      value=${BASH_REMATCH[1]}
    fi
    if [[ $value =~ ^[1-9][0-9]*$ ]] && (( value < make_jobs )); then
      make_jobs=$value
    fi
    previous=$flag
  done
  if [[ ${MAKEFLAGS:-} != "-j$make_jobs" ]]; then
    export MAKEFLAGS="${MAKEFLAGS:+$MAKEFLAGS }-j$make_jobs"
  fi
  for flag in CMAKE_BUILD_PARALLEL_LEVEL CARGO_BUILD_JOBS; do
    value=${!flag:-}
    if [[ $value =~ ^[1-9][0-9]*$ ]] && (( value < jobs )); then
      export "$flag=$value"
    else
      export "$flag=$jobs"
    fi
  done

  # makepkg consumes the arrays when sourced in its own process. Environment
  # variables also reach child builds. Keep tighter explicit thread hints.
  value=${ZSTD_NBTHREADS:-$jobs}
  [[ $value =~ ^[1-9][0-9]*$ ]] && (( value <= jobs )) || value=$jobs
  previous=""
  for flag in "${COMPRESSZST[@]}"; do
    if [[ ( $previous == "-T" || $previous == "--threads" ) && $flag =~ ^[1-9][0-9]*$ ]]; then
      (( flag >= value )) || value=$flag
    elif [[ $flag =~ ^-T([1-9][0-9]*)$ || $flag =~ ^--threads=([1-9][0-9]*)$ ]]; then
      (( BASH_REMATCH[1] >= value )) || value=${BASH_REMATCH[1]}
    fi
    previous=$flag
  done
  export ZSTD_NBTHREADS=$value ZSTD_CLEVEL=3
  # shellcheck disable=SC2034 # Consumed by makepkg after sourcing.
  COMPRESSZST=(zstd -c -T"$value" -3 -)
  value=$jobs
  xz_memory_kib=$(( total / 4 ))
  previous=""
  read -r -a xz_flags <<<"${XZ_OPT:-}"
  for flag in "${xz_flags[@]}" "${COMPRESSXZ[@]}"; do
    if [[ ( $previous == "-T" || $previous == "--threads" ) && $flag =~ ^[1-9][0-9]*$ ]]; then
      (( flag >= value )) || value=$flag
    elif [[ $flag =~ ^-T([1-9][0-9]*)$ || $flag =~ ^--threads=([1-9][0-9]*)$ ]]; then
      (( BASH_REMATCH[1] >= value )) || value=${BASH_REMATCH[1]}
    fi
    case "$flag" in
      --memlimit-compress=*|--memlimit=*)
        if [[ ${flag#*=} =~ ^([1-9][0-9]{0,11})(%|[kKmMgG]([iI]?[bB])?|[bB])?$ ]]; then
          memory_value=${BASH_REMATCH[1]} memory_unit=${BASH_REMATCH[2],,}
          case "$memory_unit" in
            '%')
              if (( memory_value < 25 )); then
                candidate_kib=$(( total * memory_value / 100 ))
              else
                candidate_kib=$xz_memory_kib
              fi
              ;;
            k|kb|kib) candidate_kib=$memory_value ;;
            m|mb|mib) candidate_kib=$(( memory_value * 1024 )) ;;
            g|gb|gib) candidate_kib=$(( memory_value * 1048576 )) ;;
            *) candidate_kib=$(( (memory_value + 1023) / 1024 )) ;;
          esac
          if (( candidate_kib > 0 && candidate_kib < xz_memory_kib )); then
            xz_memory=${flag#*=} xz_memory_kib=$candidate_kib
          fi
        fi
        ;;
    esac
    previous=$flag
  done
  export XZ_OPT="-T$value -3 --memlimit-compress=$xz_memory"
  # shellcheck disable=SC2034 # Consumed by makepkg after sourcing.
  COMPRESSXZ=(xz -c -z -T"$value" -3 "--memlimit-compress=$xz_memory" -)
}
if omarchy_pi_build_budget; then
  unset -f omarchy_pi_build_budget
else
  unset -f omarchy_pi_build_budget
  return 1
fi
