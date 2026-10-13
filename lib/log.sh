# shellcheck shell=bash
# Logging: stderr output gated on the configured level, plus an optional durable log file.

LOG_LEVEL_THRESHOLD=20
LOG_FILE=""
LOG_WITH_TIMESTAMPS=0

# Prints the numeric severity of a level name, or nothing if the name is unknown.
log_level_number() {
  local LEVEL_NAME="$1"
  local LEVEL_NUMBER=""
  case "${LEVEL_NAME}" in
    debug) LEVEL_NUMBER=10 ;;
    info) LEVEL_NUMBER=20 ;;
    warn) LEVEL_NUMBER=30 ;;
    error) LEVEL_NUMBER=40 ;;
    *) LEVEL_NUMBER="" ;;
  esac
  printf '%s' "${LEVEL_NUMBER}"
}

# Writes one log line to stderr (if at or above the threshold) and to LOG_FILE (if set).
log_write() {
  local LEVEL_NAME="$1"
  shift
  local MESSAGE="$*"
  local LEVEL_NUMBER
  LEVEL_NUMBER="$(log_level_number "${LEVEL_NAME}")"
  local TIMESTAMP
  printf -v TIMESTAMP '%(%Y-%m-%d %H:%M:%S)T' -1

  if (( LEVEL_NUMBER >= LOG_LEVEL_THRESHOLD )); then
    if (( LOG_WITH_TIMESTAMPS == 1 )); then
      printf '%s [%s] %s\n' "${TIMESTAMP}" "${LEVEL_NAME}" "${MESSAGE}" >&2
    elif [[ "${LEVEL_NAME}" == "info" ]]; then
      printf '%s\n' "${MESSAGE}" >&2
    else
      printf 'headrun: %s: %s\n' "${LEVEL_NAME}" "${MESSAGE}" >&2
    fi
  fi

  if [[ -n "${LOG_FILE}" ]]; then
    printf '%s [%s] [%s] %s\n' "${TIMESTAMP}" "$$" "${LEVEL_NAME}" "${MESSAGE}" >> "${LOG_FILE}"
  fi
}

# Logs at debug level.
log_debug() { log_write debug "$@"; }

# Logs at info level.
log_info() { log_write info "$@"; }

# Logs at warn level.
log_warn() { log_write warn "$@"; }

# Logs at error level.
log_error() { log_write error "$@"; }

# Logs an error and exits with status 1.
die() {
  log_error "$@"
  exit 1
}
