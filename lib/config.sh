# shellcheck shell=bash
# Configuration: the only place the environment is read. Loads and validates the config file.

# Paths
APP_ROOT=""
CONFIG_DIR=""
CONFIG_FILE=""
DATA_ROOT=""
JOBS_ROOT=""
QUEUE_LOCK_FILE=""
RUNNER_LOCK_FILE=""
RUNNER_PID_FILE=""
PAUSED_FLAG_FILE=""
STOP_FLAG_FILE=""
HEADRUN_LOG_PATH=""

# Environment-derived values
USER_HOME=""
HOST_NAME=""
EDITOR_COMMAND=""
CURRENT_SEARCH_PATH=""
COLOUR_ALLOWED=1
HEADRUN_VERSION=""

# Config file values (defaults; overridden by the config file)
CFG_DEFAULT_ENGINE=""
CFG_DEFAULT_WORKDIR=""
CFG_DEFAULT_TIMEOUT="2h"
CFG_DEFAULT_PRIORITY="50"
CFG_DEFAULT_PERMISSIONS="bypass"
CFG_LOG_LEVEL="info"
CFG_POLL_INTERVAL="5s"
CFG_KILL_GRACE="30s"
CFG_RECENT_LIMIT="10"
CFG_PRUNE_AFTER="30d"
declare -gA CFG_ENGINE_BINS=()

# Derived numeric values
DEFAULT_TIMEOUT_SECONDS=0
POLL_INTERVAL_SECONDS=0
KILL_GRACE_SECONDS=0
PRUNE_AFTER_SECONDS=0

PERMISSION_MODES="bypass auto edits readonly"

# Reads environment variables into globals; must be called before anything else.
config_read_environment() {
  local ENTRY_SCRIPT="$1"
  local -a ENVIRONMENT_ERRORS=()

  APP_ROOT="$(cd "$(dirname "$(readlink -f "${ENTRY_SCRIPT}")")/.." && pwd)"
  USER_HOME="${HOME:-}"
  if [[ -z "${USER_HOME}" ]]; then
    ENVIRONMENT_ERRORS+=("HOME is not set")
  fi

  local XDG_CONFIG_BASE="${XDG_CONFIG_HOME:-${USER_HOME}/.config}"
  local XDG_DATA_BASE="${XDG_DATA_HOME:-${USER_HOME}/.local/share}"
  CONFIG_DIR="${HEADRUN_CONFIG_DIR:-${XDG_CONFIG_BASE}/headrun}"
  DATA_ROOT="${HEADRUN_HOME:-${XDG_DATA_BASE}/headrun}"

  if [[ "${CONFIG_DIR}" != /* ]]; then
    ENVIRONMENT_ERRORS+=("config directory must be an absolute path: ${CONFIG_DIR}")
  fi
  if [[ "${DATA_ROOT}" != /* ]]; then
    ENVIRONMENT_ERRORS+=("data directory must be an absolute path: ${DATA_ROOT}")
  fi

  EDITOR_COMMAND="${VISUAL:-${EDITOR:-vi}}"
  HOST_NAME="${HOSTNAME:-unknown}"
  CURRENT_SEARCH_PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}"
  if [[ -n "${NO_COLOR:-}" ]]; then
    COLOUR_ALLOWED=0
  fi

  if (( ${#ENVIRONMENT_ERRORS[@]} > 0 )); then
    local ENVIRONMENT_ERROR
    for ENVIRONMENT_ERROR in "${ENVIRONMENT_ERRORS[@]}"; do
      log_error "${ENVIRONMENT_ERROR}"
    done
    exit 1
  fi

  CONFIG_FILE="${CONFIG_DIR}/config"
  JOBS_ROOT="${DATA_ROOT}/jobs"
  QUEUE_LOCK_FILE="${DATA_ROOT}/queue.lock"
  RUNNER_LOCK_FILE="${DATA_ROOT}/runner.lock"
  RUNNER_PID_FILE="${DATA_ROOT}/runner.pid"
  PAUSED_FLAG_FILE="${DATA_ROOT}/paused"
  STOP_FLAG_FILE="${DATA_ROOT}/stop-requested"
  HEADRUN_LOG_PATH="${DATA_ROOT}/headrun.log"

  HEADRUN_VERSION="unknown"
  if [[ -r "${APP_ROOT}/VERSION" ]]; then
    HEADRUN_VERSION="$(< "${APP_ROOT}/VERSION")"
  fi
}

# Parses the config file into CFG_* globals and validates everything, reporting all problems at once.
config_load() {
  local -a CONFIG_ERRORS=()

  if [[ -f "${CONFIG_FILE}" ]]; then
    local LINE_NUMBER=0
    local CONFIG_LINE
    while IFS= read -r CONFIG_LINE || [[ -n "${CONFIG_LINE}" ]]; do
      LINE_NUMBER=$(( LINE_NUMBER + 1 ))
      CONFIG_LINE="$(trim "${CONFIG_LINE}")"
      if [[ -z "${CONFIG_LINE}" || "${CONFIG_LINE}" == \#* ]]; then
        continue
      fi
      if [[ ! "${CONFIG_LINE}" =~ ^([A-Z][A-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
        CONFIG_ERRORS+=("${CONFIG_FILE}:${LINE_NUMBER}: expected KEY=value")
        continue
      fi
      local CONFIG_KEY="${BASH_REMATCH[1]}"
      local CONFIG_VALUE="${BASH_REMATCH[2]}"
      if [[ "${CONFIG_VALUE}" =~ ^\"(.*)\"$ || "${CONFIG_VALUE}" =~ ^\'(.*)\'$ ]]; then
        CONFIG_VALUE="${BASH_REMATCH[1]}"
      fi
      case "${CONFIG_KEY}" in
        DEFAULT_ENGINE) CFG_DEFAULT_ENGINE="${CONFIG_VALUE}" ;;
        DEFAULT_WORKDIR) CFG_DEFAULT_WORKDIR="${CONFIG_VALUE}" ;;
        DEFAULT_TIMEOUT) CFG_DEFAULT_TIMEOUT="${CONFIG_VALUE}" ;;
        DEFAULT_PRIORITY) CFG_DEFAULT_PRIORITY="${CONFIG_VALUE}" ;;
        DEFAULT_PERMISSIONS) CFG_DEFAULT_PERMISSIONS="${CONFIG_VALUE}" ;;
        LOG_LEVEL) CFG_LOG_LEVEL="${CONFIG_VALUE}" ;;
        POLL_INTERVAL) CFG_POLL_INTERVAL="${CONFIG_VALUE}" ;;
        KILL_GRACE) CFG_KILL_GRACE="${CONFIG_VALUE}" ;;
        RECENT_LIMIT) CFG_RECENT_LIMIT="${CONFIG_VALUE}" ;;
        PRUNE_AFTER) CFG_PRUNE_AFTER="${CONFIG_VALUE}" ;;
        *_BIN)
          local ENGINE_KEY="${CONFIG_KEY%_BIN}"
          ENGINE_KEY="${ENGINE_KEY,,}"
          CFG_ENGINE_BINS["${ENGINE_KEY//_/-}"]="${CONFIG_VALUE}"
          ;;
        *) CONFIG_ERRORS+=("${CONFIG_FILE}:${LINE_NUMBER}: unknown setting ${CONFIG_KEY}") ;;
      esac
    done < "${CONFIG_FILE}"
  fi

  if [[ "${CFG_DEFAULT_ENGINE}" == "null" || "${CFG_DEFAULT_ENGINE}" == "none" ]]; then
    CFG_DEFAULT_ENGINE=""
  fi
  if [[ -n "${CFG_DEFAULT_ENGINE}" && ! "${CFG_DEFAULT_ENGINE}" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
    CONFIG_ERRORS+=("DEFAULT_ENGINE must be an engine name (a-z, 0-9, _ or -), or empty: ${CFG_DEFAULT_ENGINE}")
  fi
  if [[ -n "${CFG_DEFAULT_WORKDIR}" && "${CFG_DEFAULT_WORKDIR}" != /* ]]; then
    CONFIG_ERRORS+=("DEFAULT_WORKDIR must be an absolute path: ${CFG_DEFAULT_WORKDIR}")
  fi
  if ! DEFAULT_TIMEOUT_SECONDS="$(duration_to_seconds "${CFG_DEFAULT_TIMEOUT}")" || (( DEFAULT_TIMEOUT_SECONDS == 0 )); then
    CONFIG_ERRORS+=("DEFAULT_TIMEOUT must be a positive duration such as 90m or 2h: ${CFG_DEFAULT_TIMEOUT}")
  fi
  if ! POLL_INTERVAL_SECONDS="$(duration_to_seconds "${CFG_POLL_INTERVAL}")" || (( POLL_INTERVAL_SECONDS == 0 )); then
    CONFIG_ERRORS+=("POLL_INTERVAL must be a positive duration such as 5s: ${CFG_POLL_INTERVAL}")
  fi
  if ! KILL_GRACE_SECONDS="$(duration_to_seconds "${CFG_KILL_GRACE}")" || (( KILL_GRACE_SECONDS == 0 )); then
    CONFIG_ERRORS+=("KILL_GRACE must be a positive duration such as 30s: ${CFG_KILL_GRACE}")
  fi
  if ! PRUNE_AFTER_SECONDS="$(duration_to_seconds "${CFG_PRUNE_AFTER}")"; then
    CONFIG_ERRORS+=("PRUNE_AFTER must be a duration such as 30d: ${CFG_PRUNE_AFTER}")
  fi
  if [[ ! "${CFG_DEFAULT_PRIORITY}" =~ ^[0-9]{1,3}$ ]]; then
    CONFIG_ERRORS+=("DEFAULT_PRIORITY must be an integer from 0 to 999: ${CFG_DEFAULT_PRIORITY}")
  fi
  if [[ ! "${CFG_RECENT_LIMIT}" =~ ^[0-9]+$ ]]; then
    CONFIG_ERRORS+=("RECENT_LIMIT must be a non-negative integer: ${CFG_RECENT_LIMIT}")
  fi
  if [[ " ${PERMISSION_MODES} " != *" ${CFG_DEFAULT_PERMISSIONS} "* ]]; then
    CONFIG_ERRORS+=("DEFAULT_PERMISSIONS must be one of: ${PERMISSION_MODES}: ${CFG_DEFAULT_PERMISSIONS}")
  fi
  local LOG_LEVEL_VALUE
  LOG_LEVEL_VALUE="$(log_level_number "${CFG_LOG_LEVEL}")"
  if [[ -z "${LOG_LEVEL_VALUE}" ]]; then
    CONFIG_ERRORS+=("LOG_LEVEL must be one of: debug info warn error: ${CFG_LOG_LEVEL}")
  else
    LOG_LEVEL_THRESHOLD="${LOG_LEVEL_VALUE}"
  fi

  if (( ${#CONFIG_ERRORS[@]} > 0 )); then
    local CONFIG_ERROR
    for CONFIG_ERROR in "${CONFIG_ERRORS[@]}"; do
      log_error "${CONFIG_ERROR}"
    done
    die "configuration is invalid (${#CONFIG_ERRORS[@]} problem(s)); fix ${CONFIG_FILE}"
  fi

  colour_init "${COLOUR_ALLOWED}"
}

# Prints the configured binary for an engine, defaulting to the engine name.
config_engine_bin() {
  local ENGINE_NAME="$1"
  printf '%s' "${CFG_ENGINE_BINS[${ENGINE_NAME}]:-${ENGINE_NAME}}"
}
