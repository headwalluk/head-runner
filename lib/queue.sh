# shellcheck shell=bash
# Queue: job directories, locking, metadata, lookup and validation.

JOB_STATES=(incoming pending running done failed cancelled archive)
VISIBLE_STATES=(running pending done failed cancelled archive)
FINISHED_STATES=(done failed cancelled)
KNOWN_FRONTMATTER_KEYS="title engine model workdir create_workdir dirs priority timeout permissions"

# Lookup results (set by job_find)
FOUND_JOB_ID=""
FOUND_JOB_STATE=""
FOUND_JOB_DIR=""

# Validation results (set by jobsheet_validate)
VALIDATION_ERRORS=()
VALIDATION_WARNINGS=()

# Creates the data directory tree with owner-only permissions.
queue_ensure_dirs() {
  if [[ ! -d "${DATA_ROOT}" ]]; then
    mkdir -p "${DATA_ROOT}"
    chmod 700 "${DATA_ROOT}"
  fi
  local STATE_NAME
  for STATE_NAME in "${JOB_STATES[@]}"; do
    if [[ ! -d "${JOBS_ROOT}/${STATE_NAME}" ]]; then
      mkdir -p "${JOBS_ROOT}/${STATE_NAME}"
    fi
  done
}

# Runs a command while holding the queue lock; callers must not run this inside a conditional.
with_queue_lock() {
  local QUEUE_LOCK_FD
  exec {QUEUE_LOCK_FD}>>"${QUEUE_LOCK_FILE}"
  if ! flock --wait 30 "${QUEUE_LOCK_FD}"; then
    die "timed out waiting for the queue lock (${QUEUE_LOCK_FILE})"
  fi
  "$@"
  exec {QUEUE_LOCK_FD}>&-
}

# Prints the value of a key in a job's meta file, or the given default.
meta_get() {
  local JOB_DIR="$1"
  local META_KEY="$2"
  local DEFAULT_VALUE="${3:-}"
  local META_VALUE=""
  if [[ -f "${JOB_DIR}/meta" ]]; then
    META_VALUE="$(awk -v meta_key="${META_KEY}" 'index($0, meta_key "=") == 1 { value = substr($0, length(meta_key) + 2) } END { printf "%s", value }' "${JOB_DIR}/meta")"
  fi
  if [[ -z "${META_VALUE}" ]]; then
    META_VALUE="${DEFAULT_VALUE}"
  fi
  printf '%s' "${META_VALUE}"
}

# Sets a key in a job's meta file (single-line values; newlines become spaces).
meta_set() {
  local JOB_DIR="$1"
  local META_KEY="$2"
  local META_VALUE="$3"
  META_VALUE="${META_VALUE//$'\n'/ }"
  META_VALUE="${META_VALUE//$'\r'/}"
  local META_FILE="${JOB_DIR}/meta"
  local TEMPORARY_FILE="${META_FILE}.tmp.$$"
  if [[ -f "${META_FILE}" ]]; then
    awk -v meta_key="${META_KEY}" 'index($0, meta_key "=") != 1' "${META_FILE}" > "${TEMPORARY_FILE}"
  else
    : > "${TEMPORARY_FILE}"
  fi
  printf '%s=%s\n' "${META_KEY}" "${META_VALUE}" >> "${TEMPORARY_FILE}"
  mv -f "${TEMPORARY_FILE}" "${META_FILE}"
}

# Prints "state<TAB>job id" for every job in the given states.
queue_list_jobs() {
  local STATE_NAME JOB_PATH
  for STATE_NAME in "$@"; do
    for JOB_PATH in "${JOBS_ROOT}/${STATE_NAME}"/*/; do
      if [[ ! -d "${JOB_PATH}" ]]; then
        continue
      fi
      JOB_PATH="${JOB_PATH%/}"
      printf '%s\t%s\n' "${STATE_NAME}" "${JOB_PATH##*/}"
    done
  done
}

# Resolves a job query (exact id, unique prefix, or unique substring) into FOUND_JOB_*; dies if none or ambiguous.
job_find() {
  local JOB_QUERY="$1"
  local -a EXACT_MATCHES=() PREFIX_MATCHES=() SUBSTRING_MATCHES=()
  local STATE_NAME JOB_ID
  while IFS=$'\t' read -r STATE_NAME JOB_ID; do
    if [[ "${JOB_ID}" == "${JOB_QUERY}" ]]; then
      EXACT_MATCHES+=("${STATE_NAME}/${JOB_ID}")
    elif [[ "${JOB_ID}" == "${JOB_QUERY}"* ]]; then
      PREFIX_MATCHES+=("${STATE_NAME}/${JOB_ID}")
    elif [[ "${JOB_ID}" == *"${JOB_QUERY}"* ]]; then
      SUBSTRING_MATCHES+=("${STATE_NAME}/${JOB_ID}")
    fi
  done < <(queue_list_jobs "${VISIBLE_STATES[@]}")

  local -a CHOSEN_MATCHES=()
  if (( ${#EXACT_MATCHES[@]} > 0 )); then
    CHOSEN_MATCHES=("${EXACT_MATCHES[@]}")
  elif (( ${#PREFIX_MATCHES[@]} > 0 )); then
    CHOSEN_MATCHES=("${PREFIX_MATCHES[@]}")
  elif (( ${#SUBSTRING_MATCHES[@]} > 0 )); then
    CHOSEN_MATCHES=("${SUBSTRING_MATCHES[@]}")
  fi

  if (( ${#CHOSEN_MATCHES[@]} == 0 )); then
    die "no job matches \"${JOB_QUERY}\""
  fi
  if (( ${#CHOSEN_MATCHES[@]} > 1 )); then
    log_error "\"${JOB_QUERY}\" matches more than one job:"
    local CANDIDATE
    for CANDIDATE in "${CHOSEN_MATCHES[@]}"; do
      printf '  %s\n' "${CANDIDATE}" >&2
    done
    exit 1
  fi

  FOUND_JOB_STATE="${CHOSEN_MATCHES[0]%%/*}"
  FOUND_JOB_ID="${CHOSEN_MATCHES[0]#*/}"
  FOUND_JOB_DIR="${JOBS_ROOT}/${FOUND_JOB_STATE}/${FOUND_JOB_ID}"
}

# Sets FOUND_JOB_* to the running job, else the most recently finished job; dies if there are none.
job_find_latest() {
  local LATEST_STATE="" LATEST_ID="" LATEST_EPOCH=-1
  local STATE_NAME JOB_ID
  while IFS=$'\t' read -r STATE_NAME JOB_ID; do
    local JOB_EPOCH
    if [[ "${STATE_NAME}" == "running" ]]; then
      JOB_EPOCH=9999999999
    else
      JOB_EPOCH="$(meta_get "${JOBS_ROOT}/${STATE_NAME}/${JOB_ID}" finished_at 0)"
    fi
    if (( JOB_EPOCH > LATEST_EPOCH )); then
      LATEST_EPOCH="${JOB_EPOCH}"
      LATEST_STATE="${STATE_NAME}"
      LATEST_ID="${JOB_ID}"
    fi
  done < <(queue_list_jobs running "${FINISHED_STATES[@]}")

  if [[ -z "${LATEST_ID}" ]]; then
    die "there are no running or finished jobs"
  fi
  FOUND_JOB_STATE="${LATEST_STATE}"
  FOUND_JOB_ID="${LATEST_ID}"
  FOUND_JOB_DIR="${JOBS_ROOT}/${LATEST_STATE}/${LATEST_ID}"
}

# Prints a new unique job id derived from the time and title; call while holding the queue lock.
job_new_id() {
  local JOB_TITLE="$1"
  local ID_BASE
  printf -v ID_BASE '%(%Y%m%d-%H%M%S)T-%s' -1 "$(slugify "${JOB_TITLE}")"
  local CANDIDATE_ID="${ID_BASE}"
  local SUFFIX_NUMBER=1
  while compgen -G "${JOBS_ROOT}/*/${CANDIDATE_ID}" > /dev/null; do
    SUFFIX_NUMBER=$(( SUFFIX_NUMBER + 1 ))
    CANDIDATE_ID="${ID_BASE}-${SUFFIX_NUMBER}"
  done
  printf '%s' "${CANDIDATE_ID}"
}

# Prints the directory of an engine adapter (user config first, then built-in), or nothing if absent.
engine_adapter_path() {
  local ENGINE_NAME="$1"
  local ADAPTER_PATH=""
  if [[ -f "${CONFIG_DIR}/engines/${ENGINE_NAME}.sh" ]]; then
    ADAPTER_PATH="${CONFIG_DIR}/engines/${ENGINE_NAME}.sh"
  elif [[ -f "${APP_ROOT}/engines/${ENGINE_NAME}.sh" ]]; then
    ADAPTER_PATH="${APP_ROOT}/engines/${ENGINE_NAME}.sh"
  fi
  printf '%s' "${ADAPTER_PATH}"
}

# Prints the extra frontmatter keys an adapter declares on its "# headrun-keys:" line.
engine_declared_keys() {
  local ADAPTER_PATH="$1"
  awk '/^# headrun-keys:/ { sub(/^# headrun-keys:[ \t]*/, ""); gsub(/,/, " "); printf "%s ", $0 }' "${ADAPTER_PATH}"
}

# Prints the names of all available engines (built-in and user), one per line.
engine_list_names() {
  local ADAPTER_FILE
  for ADAPTER_FILE in "${APP_ROOT}"/engines/*.sh "${CONFIG_DIR}"/engines/*.sh; do
    if [[ -f "${ADAPTER_FILE}" ]]; then
      local ADAPTER_NAME="${ADAPTER_FILE##*/}"
      printf '%s\n' "${ADAPTER_NAME%.sh}"
    fi
  done | sort -u
}

# Validates a jobsheet into VALIDATION_ERRORS/VALIDATION_WARNINGS; mode is "add" or "run".
jobsheet_validate() {
  local JOBSHEET_FILE="$1"
  local VALIDATION_MODE="$2"
  VALIDATION_ERRORS=()
  VALIDATION_WARNINGS=()

  local -A JOB_FIELDS=()
  local -a PARSE_PROBLEMS=()
  frontmatter_load "${JOBSHEET_FILE}" JOB_FIELDS PARSE_PROBLEMS
  if (( ${#PARSE_PROBLEMS[@]} > 0 )); then
    VALIDATION_ERRORS+=("${PARSE_PROBLEMS[@]}")
  fi

  if [[ -z "$(frontmatter_body "${JOBSHEET_FILE}" | tr -d '[:space:]')" ]]; then
    VALIDATION_ERRORS+=("the jobsheet has no body (the request itself is empty)")
  fi

  local ENGINE_NAME="${JOB_FIELDS[engine]:-${CFG_DEFAULT_ENGINE}}"
  local ADAPTER_PATH=""
  if [[ -z "${ENGINE_NAME}" ]]; then
    if [[ "${VALIDATION_MODE}" == "run" ]]; then
      VALIDATION_ERRORS+=("no engine: the jobsheet has no \"engine:\" and DEFAULT_ENGINE is not set")
    else
      VALIDATION_WARNINGS+=("no engine: the jobsheet has no \"engine:\" and DEFAULT_ENGINE is not set; the job will fail unless a default is configured before it runs")
    fi
  else
    ADAPTER_PATH="$(engine_adapter_path "${ENGINE_NAME}")"
    if [[ -z "${ADAPTER_PATH}" ]]; then
      VALIDATION_ERRORS+=("unknown engine \"${ENGINE_NAME}\" (available: $(engine_list_names | tr '\n' ' '))")
    fi
  fi

  local WORKDIR_VALUE="${JOB_FIELDS[workdir]:-${CFG_DEFAULT_WORKDIR}}"
  if [[ -z "${WORKDIR_VALUE}" ]]; then
    VALIDATION_ERRORS+=("workdir is required (set \"workdir:\" in the frontmatter or DEFAULT_WORKDIR in the config)")
  elif [[ "${WORKDIR_VALUE}" != /* ]]; then
    VALIDATION_ERRORS+=("workdir must be an absolute path: ${WORKDIR_VALUE}")
  elif [[ ! -d "${WORKDIR_VALUE}" ]]; then
    if [[ "${JOB_FIELDS[create_workdir]:-}" =~ ^(yes|true|1)$ ]]; then
      : # created by the runner at run time
    elif [[ "${VALIDATION_MODE}" == "run" ]]; then
      VALIDATION_ERRORS+=("workdir does not exist: ${WORKDIR_VALUE} (set \"create_workdir: yes\" to have it created)")
    else
      VALIDATION_WARNINGS+=("workdir does not exist yet: ${WORKDIR_VALUE} (it must exist when the job runs, or set \"create_workdir: yes\")")
    fi
  fi

  if [[ -n "${JOB_FIELDS[create_workdir]:-}" && ! "${JOB_FIELDS[create_workdir]}" =~ ^(yes|no|true|false|1|0)$ ]]; then
    VALIDATION_ERRORS+=("create_workdir must be yes or no: ${JOB_FIELDS[create_workdir]}")
  fi

  if [[ -n "${JOB_FIELDS[dirs]:-}" ]]; then
    local EXTRA_DIRECTORY
    local -a EXTRA_DIRECTORIES=()
    IFS=',' read -ra EXTRA_DIRECTORIES <<< "${JOB_FIELDS[dirs]}"
    for EXTRA_DIRECTORY in "${EXTRA_DIRECTORIES[@]}"; do
      EXTRA_DIRECTORY="$(trim "${EXTRA_DIRECTORY}")"
      if [[ "${EXTRA_DIRECTORY}" != /* ]]; then
        VALIDATION_ERRORS+=("dirs entries must be absolute paths: ${EXTRA_DIRECTORY}")
      elif [[ ! -d "${EXTRA_DIRECTORY}" ]]; then
        VALIDATION_WARNINGS+=("dirs entry does not exist: ${EXTRA_DIRECTORY}")
      fi
    done
  fi

  if [[ -n "${JOB_FIELDS[priority]:-}" && ! "${JOB_FIELDS[priority]}" =~ ^[0-9]{1,3}$ ]]; then
    VALIDATION_ERRORS+=("priority must be an integer from 0 to 999: ${JOB_FIELDS[priority]}")
  fi

  if [[ -n "${JOB_FIELDS[timeout]:-}" ]]; then
    local TIMEOUT_SECONDS
    if ! TIMEOUT_SECONDS="$(duration_to_seconds "${JOB_FIELDS[timeout]}")" || (( TIMEOUT_SECONDS == 0 )); then
      VALIDATION_ERRORS+=("timeout must be a positive duration such as 90m or 2h: ${JOB_FIELDS[timeout]}")
    fi
  fi

  if [[ -n "${JOB_FIELDS[permissions]:-}" && " ${PERMISSION_MODES} " != *" ${JOB_FIELDS[permissions]} "* ]]; then
    VALIDATION_ERRORS+=("permissions must be one of: ${PERMISSION_MODES}: ${JOB_FIELDS[permissions]}")
  fi

  local ALLOWED_KEYS="${KNOWN_FRONTMATTER_KEYS}"
  if [[ -n "${ADAPTER_PATH}" ]]; then
    ALLOWED_KEYS+=" $(engine_declared_keys "${ADAPTER_PATH}")"
  fi
  local FIELD_KEY
  for FIELD_KEY in "${!JOB_FIELDS[@]}"; do
    if [[ " ${ALLOWED_KEYS} " != *" ${FIELD_KEY} "* ]]; then
      VALIDATION_WARNINGS+=("unknown frontmatter key \"${FIELD_KEY}\" (passed to the engine as HEADRUN_FM_${FIELD_KEY^^})")
    fi
  done
}

# Prints validation problems; returns 1 if there were errors.
jobsheet_report_validation() {
  local REPORT_LABEL="$1"
  local VALIDATION_MESSAGE
  for VALIDATION_MESSAGE in "${VALIDATION_WARNINGS[@]}"; do
    log_warn "${REPORT_LABEL}: ${VALIDATION_MESSAGE}"
  done
  for VALIDATION_MESSAGE in "${VALIDATION_ERRORS[@]}"; do
    log_error "${REPORT_LABEL}: ${VALIDATION_MESSAGE}"
  done
  (( ${#VALIDATION_ERRORS[@]} == 0 ))
}

# Prints the title for a jobsheet: frontmatter title, else first heading, else the fallback.
jobsheet_title() {
  local JOBSHEET_FILE="$1"
  local FALLBACK_TITLE="$2"
  local JOB_TITLE
  JOB_TITLE="$(frontmatter_read "${JOBSHEET_FILE}" | awk -F'\t' '$1 == "title" { print $2; exit }')"
  if [[ -z "${JOB_TITLE}" ]]; then
    JOB_TITLE="$(frontmatter_first_heading "${JOBSHEET_FILE}")"
  fi
  if [[ -z "${JOB_TITLE}" ]]; then
    JOB_TITLE="${FALLBACK_TITLE}"
  fi
  printf '%s' "${JOB_TITLE}"
}

# Moves a prepared draft into the queue as a new pending job and sets ENQUEUED_JOB_ID; call under the queue lock.
queue_enqueue_locked() {
  local DRAFT_FILE="$1"
  local JOB_TITLE="$2"
  local REQUEUED_FROM="$3"
  ENQUEUED_JOB_ID="$(job_new_id "${JOB_TITLE}")"
  local INCOMING_DIR="${JOBS_ROOT}/incoming/${ENQUEUED_JOB_ID}"
  mkdir "${INCOMING_DIR}"
  mv "${DRAFT_FILE}" "${INCOMING_DIR}/request.md"
  meta_set "${INCOMING_DIR}" title "${JOB_TITLE}"
  meta_set "${INCOMING_DIR}" queued_at "$(now_epoch)"
  meta_set "${INCOMING_DIR}" queued_order "$(date +%s%N)"
  if [[ -n "${REQUEUED_FROM}" ]]; then
    meta_set "${INCOMING_DIR}" requeued_from "${REQUEUED_FROM}"
  fi
  mv "${INCOMING_DIR}" "${JOBS_ROOT}/pending/${ENQUEUED_JOB_ID}"
}

# Prints the priority of a pending job (frontmatter, else the configured default).
job_priority() {
  local JOB_DIR="$1"
  local JOB_PRIORITY
  JOB_PRIORITY="$(frontmatter_read "${JOB_DIR}/request.md" | awk -F'\t' '$1 == "priority" { print $2; exit }')"
  if [[ ! "${JOB_PRIORITY}" =~ ^[0-9]{1,3}$ ]]; then
    JOB_PRIORITY="${CFG_DEFAULT_PRIORITY}"
  fi
  printf '%s' "$(( 10#${JOB_PRIORITY} ))"
}

# Prints pending job ids in run order: priority ascending, then oldest first (nanosecond queue order).
queue_pending_in_order() {
  local STATE_NAME JOB_ID
  while IFS=$'\t' read -r STATE_NAME JOB_ID; do
    local JOB_DIR="${JOBS_ROOT}/${STATE_NAME}/${JOB_ID}"
    local QUEUED_ORDER
    QUEUED_ORDER="$(meta_get "${JOB_DIR}" queued_order)"
    if [[ -z "${QUEUED_ORDER}" ]]; then
      QUEUED_ORDER="$(meta_get "${JOB_DIR}" queued_at 0)000000000"
    fi
    printf '%03d\t%s\t%s\n' "$(job_priority "${JOB_DIR}")" "${QUEUED_ORDER}" "${JOB_ID}"
  done < <(queue_list_jobs pending) | sort -t $'\t' -k1,1n -k2,2n -k3,3 | cut -f3
}
