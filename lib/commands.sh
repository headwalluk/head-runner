# shellcheck shell=bash
# CLI subcommands and dispatch.

DRAFT_FILE=""
ENQUEUED_JOB_ID=""

# Prints top-level usage.
cmd_help() {
  cat <<EOF
headrun ${HEADRUN_VERSION} — Markdown in, Markdown out job queue for agentic coding tasks.

Usage: headrun <command> [options]

Queue
  add [options] [FILE|-]    Queue a jobsheet (reads stdin when FILE is - or omitted)
  new [options]             Write a jobsheet in \$EDITOR from a template, then queue it
  ls [--all] [--state S]    List the queue and recent jobs
  show [ID] [--request|--prompt|--log|--meta|--path]
                            Show a job's response (default: running or latest job)
  tail [ID]                 Follow a job's transcript (default: the running job)
  edit ID                   Edit a pending job's jobsheet
  bump ID PRIORITY          Change a pending job's priority (lower runs first)
  cancel ID...              Cancel pending jobs
  requeue ID [--edit] [--priority N]
                            Queue a copy of a finished job's request
  prune [--older-than D] [--delete] [--dry-run]
                            Archive (or delete) finished jobs older than D

Runner
  run [--once] [--watch] [--detach] [--quiet]
                            Run jobs: drain the queue (default), one job, or watch forever
  pause | resume            Pause/resume the queue (the current job finishes first)
  stop [--now]              Ask the runner to exit after the current job (--now: kill it)
  status                    Runner and queue status
  log [-f] [-n LINES]       Show the runner log

Setup
  doctor                    Check dependencies, configuration and engines
  install-service [--enable]
                            Write a systemd user unit that runs "headrun run --watch"
  version                   Print the version

add/new options:
  -e, --engine NAME   -m, --model NAME   -w, --workdir DIR   -p, --priority N
  -t, --timeout DUR   --title TEXT       --permissions MODE  --dirs DIR[,DIR]
  --check             Validate only; do not queue

IDs may be abbreviated to any unique prefix or substring.
Config: ${CONFIG_FILE}
Data:   ${DATA_ROOT}
EOF
}

# Prints the version.
cmd_version() {
  printf 'headrun %s\n' "${HEADRUN_VERSION}"
}

# Removes the working draft file, if any, on exit.
draft_cleanup() {
  if [[ -n "${DRAFT_FILE}" && -f "${DRAFT_FILE}" ]]; then
    rm -f "${DRAFT_FILE}"
  fi
}

# Creates an empty draft file in incoming/ and registers it for cleanup.
draft_create() {
  queue_ensure_dirs
  DRAFT_FILE="$(mktemp "${JOBS_ROOT}/incoming/.draft-XXXXXX.md")"
  trap draft_cleanup EXIT
}

# Opens a file in the configured editor.
open_in_editor() {
  local EDIT_TARGET="$1"
  # A shell parses the editor command so quoted arguments work, e.g. VISUAL='emacsclient -t -a ""'.
  sh -c "${EDITOR_COMMAND} \"\$1\"" headrun-editor "${EDIT_TARGET}" < /dev/tty > /dev/tty
}

# Opens the draft in the editor until it validates, or the operator aborts.
edit_until_valid() {
  local EDIT_TARGET="$1"
  local EDIT_LABEL="$2"
  while true; do
    open_in_editor "${EDIT_TARGET}"
    jobsheet_validate "${EDIT_TARGET}" add
    if jobsheet_report_validation "${EDIT_LABEL}"; then
      break
    fi
    local EDIT_CHOICE=""
    read -rp "Re-edit (e) or abort (a)? [e] " EDIT_CHOICE < /dev/tty
    if [[ "${EDIT_CHOICE}" == "a" || "${EDIT_CHOICE}" == "abort" ]]; then
      die "aborted; nothing was queued"
    fi
  done
}

# Applies --engine/--workdir/etc. option overrides to a draft's frontmatter.
apply_frontmatter_overrides() {
  local DRAFT_PATH="$1"
  local -n OVERRIDES_REFERENCE="$2"
  local OVERRIDE_KEY
  for OVERRIDE_KEY in title engine model workdir priority timeout permissions dirs; do
    if [[ -n "${OVERRIDES_REFERENCE[${OVERRIDE_KEY}]:-}" ]]; then
      frontmatter_set "${DRAFT_PATH}" "${OVERRIDE_KEY}" "${OVERRIDES_REFERENCE[${OVERRIDE_KEY}]}"
    fi
  done
}

# Parses one add/new option into the named overrides array; prints how many arguments were consumed.
parse_override_option() {
  local -n PARSED_OVERRIDES="$1"
  local OPTION_NAME="$2"
  local OPTION_VALUE="${3:-}"
  local OVERRIDE_KEY=""
  case "${OPTION_NAME}" in
    -e|--engine) OVERRIDE_KEY=engine ;;
    -m|--model) OVERRIDE_KEY=model ;;
    -w|--workdir) OVERRIDE_KEY=workdir ;;
    -p|--priority) OVERRIDE_KEY=priority ;;
    -t|--timeout) OVERRIDE_KEY=timeout ;;
    --title) OVERRIDE_KEY=title ;;
    --permissions) OVERRIDE_KEY=permissions ;;
    --dirs) OVERRIDE_KEY=dirs ;;
    *) die "unknown option: ${OPTION_NAME}" ;;
  esac
  if [[ -z "${OPTION_VALUE}" ]]; then
    die "${OPTION_NAME} needs a value"
  fi
  if [[ "${OPTION_VALUE}" == *[$'\t\n\r']* ]]; then
    die "${OPTION_NAME} value must not contain tabs or line breaks"
  fi
  if [[ "${OVERRIDE_KEY}" == "workdir" && "${OPTION_VALUE}" != /* ]]; then
    OPTION_VALUE="$(readlink -m "${OPTION_VALUE}")"
  fi
  # shellcheck disable=SC2034 # nameref into the caller's array
  PARSED_OVERRIDES["${OVERRIDE_KEY}"]="${OPTION_VALUE}"
}

# Validates the draft, queues it, and prints the new job id on stdout.
enqueue_draft() {
  local FALLBACK_TITLE="$1"
  local REQUEUED_FROM="$2"
  local JOB_TITLE
  JOB_TITLE="$(jobsheet_title "${DRAFT_FILE}" "${FALLBACK_TITLE}")"
  with_queue_lock queue_enqueue_locked "${DRAFT_FILE}" "${JOB_TITLE}" "${REQUEUED_FROM}"
  DRAFT_FILE=""

  local QUEUE_POSITION
  QUEUE_POSITION="$(queue_pending_in_order | grep -n -x -F -- "${ENQUEUED_JOB_ID}" | cut -d: -f1)"
  log_info "queued ${ENQUEUED_JOB_ID} (position ${QUEUE_POSITION:-?} of $(queue_pending_in_order | wc -l))"
  if [[ -f "${PAUSED_FLAG_FILE}" ]]; then
    log_info "note: the queue is paused (headrun resume)"
  fi
  printf '%s\n' "${ENQUEUED_JOB_ID}"
}

# headrun add: queue a jobsheet from a file or stdin.
cmd_add() {
  local -A OPTION_OVERRIDES=()
  local SOURCE_PATH=""
  local CHECK_ONLY=0
  while (( $# > 0 )); do
    case "$1" in
      --check) CHECK_ONLY=1; shift ;;
      -) SOURCE_PATH="-"; shift ;;
      -*) parse_override_option OPTION_OVERRIDES "$1" "${2:-}"; shift 2 ;;
      *)
        if [[ -n "${SOURCE_PATH}" ]]; then
          die "add takes a single FILE (got \"${SOURCE_PATH}\" and \"$1\")"
        fi
        SOURCE_PATH="$1"
        shift
        ;;
    esac
  done

  if [[ -z "${SOURCE_PATH}" ]]; then
    if [[ -t 0 ]]; then
      die "add needs a FILE, or a jobsheet on stdin (use headrun new to write one)"
    fi
    SOURCE_PATH="-"
  fi

  draft_create
  local FALLBACK_TITLE="job"
  if [[ "${SOURCE_PATH}" == "-" ]]; then
    cat > "${DRAFT_FILE}"
  else
    if [[ ! -f "${SOURCE_PATH}" ]]; then
      die "no such file: ${SOURCE_PATH}"
    fi
    cat -- "${SOURCE_PATH}" > "${DRAFT_FILE}"
    FALLBACK_TITLE="$(basename -- "${SOURCE_PATH}" .md)"
  fi

  apply_frontmatter_overrides "${DRAFT_FILE}" OPTION_OVERRIDES
  jobsheet_validate "${DRAFT_FILE}" add
  local REPORT_LABEL="${SOURCE_PATH/#-/stdin}"
  if ! jobsheet_report_validation "${REPORT_LABEL}"; then
    die "not queued: ${#VALIDATION_ERRORS[@]} problem(s) in the jobsheet"
  fi
  if (( CHECK_ONLY == 1 )); then
    log_info "${REPORT_LABEL}: valid (${#VALIDATION_WARNINGS[@]} warning(s))"
    return 0
  fi
  enqueue_draft "${FALLBACK_TITLE}" ""
}

# headrun new: write a jobsheet from the template in $EDITOR, then queue it.
cmd_new() {
  local -A OPTION_OVERRIDES=()
  while (( $# > 0 )); do
    case "$1" in
      -*) parse_override_option OPTION_OVERRIDES "$1" "${2:-}"; shift 2 ;;
      *) die "new takes no arguments (got \"$1\")" ;;
    esac
  done
  if [[ ! -t 0 && ! -r /dev/tty ]]; then
    die "new needs a terminal; use headrun add to queue a file"
  fi

  draft_create
  local TEMPLATE_PATH="${CONFIG_DIR}/jobsheet-template.md"
  if [[ ! -f "${TEMPLATE_PATH}" ]]; then
    TEMPLATE_PATH="${APP_ROOT}/share/jobsheet-template.md"
  fi
  cp "${TEMPLATE_PATH}" "${DRAFT_FILE}"
  if [[ -z "${OPTION_OVERRIDES[engine]:-}" && -n "${CFG_DEFAULT_ENGINE}" ]]; then
    OPTION_OVERRIDES[engine]="${CFG_DEFAULT_ENGINE}"
  fi
  if [[ -z "${OPTION_OVERRIDES[workdir]:-}" ]]; then
    OPTION_OVERRIDES[workdir]="${CFG_DEFAULT_WORKDIR:-${PWD}}"
  fi
  apply_frontmatter_overrides "${DRAFT_FILE}" OPTION_OVERRIDES

  local TEMPLATE_CHECKSUM
  TEMPLATE_CHECKSUM="$(cksum < "${DRAFT_FILE}")"
  edit_until_valid "${DRAFT_FILE}" "new jobsheet"
  if [[ "$(cksum < "${DRAFT_FILE}")" == "${TEMPLATE_CHECKSUM}" ]]; then
    die "jobsheet unchanged; nothing was queued"
  fi
  enqueue_draft "job" ""
}

# Prints a short summary of the runner state for headers.
runner_state_summary() {
  local SUMMARY_TEXT
  if runner_is_active; then
    SUMMARY_TEXT="runner ${COLOUR_GREEN}active${COLOUR_RESET} (pid $(runner_recorded_pid))"
  else
    SUMMARY_TEXT="runner ${COLOUR_DIM}not running${COLOUR_RESET}"
  fi
  if [[ -f "${PAUSED_FLAG_FILE}" ]]; then
    SUMMARY_TEXT+=", queue ${COLOUR_YELLOW}paused${COLOUR_RESET}"
  fi
  if [[ -f "${STOP_FLAG_FILE}" ]]; then
    SUMMARY_TEXT+=", ${COLOUR_YELLOW}stop requested${COLOUR_RESET}"
  fi
  printf '%s' "${SUMMARY_TEXT}"
}

# Prints the colour for a job state.
state_colour() {
  local STATE_NAME="$1"
  local STATE_COLOUR=""
  case "${STATE_NAME}" in
    running) STATE_COLOUR="${COLOUR_BLUE}${COLOUR_BOLD}" ;;
    pending) STATE_COLOUR="" ;;
    done) STATE_COLOUR="${COLOUR_GREEN}" ;;
    failed) STATE_COLOUR="${COLOUR_RED}" ;;
    cancelled|archive) STATE_COLOUR="${COLOUR_DIM}" ;;
    *) STATE_COLOUR="" ;;
  esac
  printf '%s' "${STATE_COLOUR}"
}

# Prints one ls row for a job.
print_job_row() {
  local STATE_NAME="$1"
  local JOB_ID="$2"
  local JOB_DIR="${JOBS_ROOT}/${STATE_NAME}/${JOB_ID}"
  local NOW_SECONDS
  NOW_SECONDS="$(now_epoch)"

  local ENGINE_TEXT PRIORITY_TEXT WHEN_TEXT
  ENGINE_TEXT="$(meta_get "${JOB_DIR}" engine)"
  if [[ -z "${ENGINE_TEXT}" ]]; then
    ENGINE_TEXT="$(frontmatter_value "${JOB_DIR}/request.md" engine)"
  fi
  if [[ -z "${ENGINE_TEXT}" ]]; then
    ENGINE_TEXT="${CFG_DEFAULT_ENGINE:-(none)}"
  fi
  PRIORITY_TEXT="$(job_priority "${JOB_DIR}")"

  case "${STATE_NAME}" in
    pending) WHEN_TEXT="queued $(seconds_to_human $(( NOW_SECONDS - $(meta_get "${JOB_DIR}" queued_at "${NOW_SECONDS}") ))) ago" ;;
    running) WHEN_TEXT="for $(seconds_to_human $(( NOW_SECONDS - $(meta_get "${JOB_DIR}" started_at "${NOW_SECONDS}") )))" ;;
    *) WHEN_TEXT="$(seconds_to_human $(( NOW_SECONDS - $(meta_get "${JOB_DIR}" finished_at "${NOW_SECONDS}") ))) ago" ;;
  esac

  local JOB_TITLE
  JOB_TITLE="$(meta_get "${JOB_DIR}" title)"
  if (( ${#JOB_TITLE} > 50 )); then
    JOB_TITLE="${JOB_TITLE:0:49}…"
  fi
  local REASON_TEXT=""
  if [[ "${STATE_NAME}" == "failed" ]]; then
    REASON_TEXT="$(meta_get "${JOB_DIR}" reason)"
    REASON_TEXT=" ${COLOUR_DIM}(${REASON_TEXT:0:60})${COLOUR_RESET}"
  fi

  printf '%s%-9s%s %-44s %3s  %-9s %-14s %s%s\n' \
    "$(state_colour "${STATE_NAME}")" "${STATE_NAME}" "${COLOUR_RESET}" \
    "${JOB_ID}" "${PRIORITY_TEXT}" "${ENGINE_TEXT:0:9}" "${WHEN_TEXT}" "${JOB_TITLE}" "${REASON_TEXT}"
}

# headrun ls: list running and pending jobs plus recent finished jobs.
cmd_ls() {
  local SHOW_ALL=0
  local IDS_ONLY=0
  local -a SELECTED_STATES=()
  while (( $# > 0 )); do
    case "$1" in
      -a|--all) SHOW_ALL=1; shift ;;
      -q|--quiet) IDS_ONLY=1; shift ;;
      -s|--state)
        local STATE_ARGUMENT="${2:-}"
        if [[ -z "${STATE_ARGUMENT}" ]]; then
          die "--state needs a value (${VISIBLE_STATES[*]})"
        fi
        local -a STATE_ITEMS=()
        IFS=',' read -ra STATE_ITEMS <<< "${STATE_ARGUMENT}"
        SELECTED_STATES+=("${STATE_ITEMS[@]}")
        shift 2
        ;;
      *) die "unknown ls option: $1" ;;
    esac
  done
  queue_ensure_dirs

  local STATE_NAME
  for STATE_NAME in "${SELECTED_STATES[@]}"; do
    if [[ " ${VISIBLE_STATES[*]} " != *" ${STATE_NAME} "* ]]; then
      die "unknown state \"${STATE_NAME}\" (${VISIBLE_STATES[*]})"
    fi
  done
  local LIMIT_FINISHED=1
  if (( ${#SELECTED_STATES[@]} == 0 )); then
    SELECTED_STATES=(running pending "done" failed cancelled)
    if (( SHOW_ALL == 1 )); then
      SELECTED_STATES+=(archive)
      LIMIT_FINISHED=0
    fi
  else
    LIMIT_FINISHED=0
  fi

  local -a ROWS=()
  local JOB_ID
  if [[ " ${SELECTED_STATES[*]} " == *" running "* ]]; then
    while IFS=$'\t' read -r STATE_NAME JOB_ID; do
      ROWS+=("running/${JOB_ID}")
    done < <(queue_list_jobs running)
  fi
  if [[ " ${SELECTED_STATES[*]} " == *" pending "* ]]; then
    while IFS= read -r JOB_ID; do
      ROWS+=("pending/${JOB_ID}")
    done < <(queue_pending_in_order)
  fi

  local -a FINISHED_SELECTION=()
  for STATE_NAME in "done" failed cancelled archive; do
    if [[ " ${SELECTED_STATES[*]} " == *" ${STATE_NAME} "* ]]; then
      FINISHED_SELECTION+=("${STATE_NAME}")
    fi
  done
  local HIDDEN_COUNT=0
  if (( ${#FINISHED_SELECTION[@]} > 0 )); then
    local -a FINISHED_ROWS=()
    local FINISHED_LINE
    while IFS= read -r FINISHED_LINE; do
      FINISHED_ROWS+=("${FINISHED_LINE}")
    done < <(
      while IFS=$'\t' read -r STATE_NAME JOB_ID; do
        printf '%s\t%s/%s\n' "$(meta_get "${JOBS_ROOT}/${STATE_NAME}/${JOB_ID}" finished_at 0)" "${STATE_NAME}" "${JOB_ID}"
      done < <(queue_list_jobs "${FINISHED_SELECTION[@]}") | sort -t $'\t' -k1,1nr | cut -f2
    )
    local FINISHED_INDEX=0
    for FINISHED_LINE in "${FINISHED_ROWS[@]}"; do
      if (( LIMIT_FINISHED == 1 && FINISHED_INDEX >= CFG_RECENT_LIMIT )); then
        HIDDEN_COUNT=$(( HIDDEN_COUNT + 1 ))
      else
        ROWS+=("${FINISHED_LINE}")
      fi
      FINISHED_INDEX=$(( FINISHED_INDEX + 1 ))
    done
  fi

  if (( IDS_ONLY == 1 )); then
    local ROW_ENTRY
    for ROW_ENTRY in "${ROWS[@]}"; do
      printf '%s\n' "${ROW_ENTRY#*/}"
    done
    return 0
  fi

  printf '%s\n' "$(runner_state_summary)"
  if (( ${#ROWS[@]} == 0 )); then
    printf '%sno jobs%s\n' "${COLOUR_DIM}" "${COLOUR_RESET}"
  else
    printf '%s%-9s %-44s %3s  %-9s %-14s %s%s\n' "${COLOUR_DIM}" STATE ID PRI ENGINE WHEN TITLE "${COLOUR_RESET}"
    local ROW_ENTRY
    for ROW_ENTRY in "${ROWS[@]}"; do
      print_job_row "${ROW_ENTRY%%/*}" "${ROW_ENTRY#*/}"
    done
  fi
  if (( HIDDEN_COUNT > 0 )); then
    printf '%s… %d older finished job(s) not shown (headrun ls --all)%s\n' "${COLOUR_DIM}" "${HIDDEN_COUNT}" "${COLOUR_RESET}"
  fi
}

# headrun show: print a job's response (or another of its files).
cmd_show() {
  local JOB_QUERY=""
  local SHOW_WHAT="default"
  while (( $# > 0 )); do
    case "$1" in
      -r|--request) SHOW_WHAT=request; shift ;;
      --prompt) SHOW_WHAT=prompt; shift ;;
      -l|--log|--transcript) SHOW_WHAT=transcript; shift ;;
      --meta) SHOW_WHAT=meta; shift ;;
      --path) SHOW_WHAT=path; shift ;;
      --response) SHOW_WHAT=response; shift ;;
      -*) die "unknown show option: $1" ;;
      *) JOB_QUERY="$1"; shift ;;
    esac
  done
  if [[ -n "${JOB_QUERY}" ]]; then
    job_find "${JOB_QUERY}"
  else
    job_find_latest
  fi

  local SHOW_FILE=""
  case "${SHOW_WHAT}" in
    path) printf '%s\n' "${FOUND_JOB_DIR}"; return 0 ;;
    request) SHOW_FILE="${FOUND_JOB_DIR}/request.md" ;;
    prompt) SHOW_FILE="${FOUND_JOB_DIR}/prompt.md" ;;
    transcript) SHOW_FILE="${FOUND_JOB_DIR}/transcript.log" ;;
    meta) SHOW_FILE="${FOUND_JOB_DIR}/meta" ;;
    response) SHOW_FILE="${FOUND_JOB_DIR}/response.md" ;;
    default)
      SHOW_FILE="${FOUND_JOB_DIR}/response.md"
      if [[ "${FOUND_JOB_STATE}" == "running" || ! -f "${SHOW_FILE}" ]]; then
        log_info "${FOUND_JOB_ID} is ${FOUND_JOB_STATE}; showing the request"
        SHOW_FILE="${FOUND_JOB_DIR}/request.md"
      fi
      ;;
    *) die "unknown show target: ${SHOW_WHAT}" ;;
  esac
  if [[ ! -f "${SHOW_FILE}" ]]; then
    die "${FOUND_JOB_ID} has no ${SHOW_FILE##*/} (state: ${FOUND_JOB_STATE})"
  fi
  cat -- "${SHOW_FILE}"
}

# headrun tail: follow a job transcript until the job ends.
cmd_tail() {
  local JOB_QUERY="${1:-}"
  if [[ -n "${JOB_QUERY}" ]]; then
    job_find "${JOB_QUERY}"
  else
    local RUNNING_JOB_ID
    RUNNING_JOB_ID="$(queue_running_job_id)"
    if [[ -z "${RUNNING_JOB_ID}" ]]; then
      die "no job is running (headrun tail ID to view a finished job's transcript)"
    fi
    job_find "${RUNNING_JOB_ID}"
  fi
  local TRANSCRIPT_FILE="${FOUND_JOB_DIR}/transcript.log"
  local JOB_PROCESS_ID
  JOB_PROCESS_ID="$(meta_get "${FOUND_JOB_DIR}" pid)"
  if [[ "${FOUND_JOB_STATE}" == "running" ]] && process_is_alive "${JOB_PROCESS_ID}"; then
    log_info "following ${FOUND_JOB_ID} (Ctrl-C stops following; the job keeps running)"
    tail -n +1 -f --pid="${JOB_PROCESS_ID}" "${TRANSCRIPT_FILE}"
  elif [[ -f "${TRANSCRIPT_FILE}" ]]; then
    cat -- "${TRANSCRIPT_FILE}"
  else
    die "${FOUND_JOB_ID} has no transcript (state: ${FOUND_JOB_STATE})"
  fi
}

# headrun log: print or follow the runner log.
cmd_log() {
  local FOLLOW_LOG=0
  local LINE_COUNT=50
  while (( $# > 0 )); do
    case "$1" in
      -f|--follow) FOLLOW_LOG=1; shift ;;
      -n|--lines) LINE_COUNT="${2:-}"; shift 2 ;;
      *) die "unknown log option: $1" ;;
    esac
  done
  if [[ ! "${LINE_COUNT}" =~ ^[0-9]+$ ]]; then
    die "--lines needs a number"
  fi
  if [[ ! -f "${HEADRUN_LOG_PATH}" ]]; then
    die "no runner log yet (${HEADRUN_LOG_PATH})"
  fi
  if (( FOLLOW_LOG == 1 )); then
    tail -n "${LINE_COUNT}" -f "${HEADRUN_LOG_PATH}"
  else
    tail -n "${LINE_COUNT}" "${HEADRUN_LOG_PATH}"
  fi
}

# Dies unless the found job is pending.
require_pending() {
  local ACTION_NAME="$1"
  if [[ "${FOUND_JOB_STATE}" != "pending" ]]; then
    die "cannot ${ACTION_NAME} ${FOUND_JOB_ID}: it is ${FOUND_JOB_STATE}, not pending"
  fi
}

# Replaces a pending job's request with the edited copy; call under the queue lock.
edit_commit_locked() {
  local JOB_ID="$1"
  local EDITED_FILE="$2"
  EDIT_COMMITTED=0
  if [[ -d "${JOBS_ROOT}/pending/${JOB_ID}" ]]; then
    mv -f "${EDITED_FILE}" "${JOBS_ROOT}/pending/${JOB_ID}/request.md"
    meta_set "${JOBS_ROOT}/pending/${JOB_ID}" title "$(jobsheet_title "${JOBS_ROOT}/pending/${JOB_ID}/request.md" "${JOB_ID}")"
    EDIT_COMMITTED=1
  fi
}

# headrun edit: edit a pending job's jobsheet in $EDITOR.
cmd_edit() {
  local JOB_QUERY="${1:-}"
  if [[ -z "${JOB_QUERY}" ]]; then
    die "edit needs a job ID"
  fi
  job_find "${JOB_QUERY}"
  require_pending edit
  draft_create
  cp "${FOUND_JOB_DIR}/request.md" "${DRAFT_FILE}"
  local ORIGINAL_CHECKSUM
  ORIGINAL_CHECKSUM="$(cksum < "${DRAFT_FILE}")"
  edit_until_valid "${DRAFT_FILE}" "${FOUND_JOB_ID}"
  if [[ "$(cksum < "${DRAFT_FILE}")" == "${ORIGINAL_CHECKSUM}" ]]; then
    log_info "no changes"
    return 0
  fi
  EDIT_COMMITTED=0
  with_queue_lock edit_commit_locked "${FOUND_JOB_ID}" "${DRAFT_FILE}"
  if (( EDIT_COMMITTED == 0 )); then
    local SAVED_COPY="${PWD}/${FOUND_JOB_ID}.md"
    mv "${DRAFT_FILE}" "${SAVED_COPY}"
    DRAFT_FILE=""
    die "${FOUND_JOB_ID} left the pending queue while you were editing; your edit was saved to ${SAVED_COPY}"
  fi
  DRAFT_FILE=""
  log_info "updated ${FOUND_JOB_ID}"
}

# Sets a pending job's priority; call under the queue lock.
bump_locked() {
  local JOB_ID="$1"
  local NEW_PRIORITY="$2"
  if [[ ! -d "${JOBS_ROOT}/pending/${JOB_ID}" ]]; then
    die "${JOB_ID} is no longer pending"
  fi
  frontmatter_set "${JOBS_ROOT}/pending/${JOB_ID}/request.md" priority "${NEW_PRIORITY}"
}

# headrun bump: change a pending job's priority.
cmd_bump() {
  local JOB_QUERY="${1:-}"
  local NEW_PRIORITY="${2:-}"
  if [[ -z "${JOB_QUERY}" || -z "${NEW_PRIORITY}" ]]; then
    die "usage: headrun bump ID PRIORITY (0-999, lower runs first)"
  fi
  if [[ ! "${NEW_PRIORITY}" =~ ^[0-9]{1,3}$ ]]; then
    die "priority must be an integer from 0 to 999"
  fi
  job_find "${JOB_QUERY}"
  require_pending bump
  with_queue_lock bump_locked "${FOUND_JOB_ID}" "${NEW_PRIORITY}"
  log_info "${FOUND_JOB_ID}: priority ${NEW_PRIORITY}"
}

# Moves a pending job to cancelled/; call under the queue lock.
cancel_locked() {
  local JOB_ID="$1"
  if [[ ! -d "${JOBS_ROOT}/pending/${JOB_ID}" ]]; then
    die "${JOB_ID} is no longer pending"
  fi
  meta_set "${JOBS_ROOT}/pending/${JOB_ID}" finished_at "$(now_epoch)"
  meta_set "${JOBS_ROOT}/pending/${JOB_ID}" reason "cancelled by operator"
  mv "${JOBS_ROOT}/pending/${JOB_ID}" "${JOBS_ROOT}/cancelled/${JOB_ID}"
}

# headrun cancel: cancel one or more pending jobs.
cmd_cancel() {
  if (( $# == 0 )); then
    die "cancel needs at least one job ID"
  fi
  local JOB_QUERY
  for JOB_QUERY in "$@"; do
    job_find "${JOB_QUERY}"
    if [[ "${FOUND_JOB_STATE}" == "running" ]]; then
      die "${FOUND_JOB_ID} is running; use headrun stop --now to kill it"
    fi
    require_pending cancel
    with_queue_lock cancel_locked "${FOUND_JOB_ID}"
    log_info "cancelled ${FOUND_JOB_ID}"
  done
}

# headrun requeue: queue a copy of an existing job's request.
cmd_requeue() {
  local JOB_QUERY=""
  local EDIT_FIRST=0
  local -A OPTION_OVERRIDES=()
  while (( $# > 0 )); do
    case "$1" in
      --edit) EDIT_FIRST=1; shift ;;
      -*) parse_override_option OPTION_OVERRIDES "$1" "${2:-}"; shift 2 ;;
      *) JOB_QUERY="$1"; shift ;;
    esac
  done
  if [[ -z "${JOB_QUERY}" ]]; then
    die "requeue needs a job ID"
  fi
  job_find "${JOB_QUERY}"
  if [[ "${FOUND_JOB_STATE}" == "pending" || "${FOUND_JOB_STATE}" == "running" ]]; then
    die "${FOUND_JOB_ID} is ${FOUND_JOB_STATE}; only finished jobs can be requeued"
  fi
  draft_create
  cp "${FOUND_JOB_DIR}/request.md" "${DRAFT_FILE}"
  apply_frontmatter_overrides "${DRAFT_FILE}" OPTION_OVERRIDES
  if (( EDIT_FIRST == 1 )); then
    edit_until_valid "${DRAFT_FILE}" "requeue of ${FOUND_JOB_ID}"
  else
    jobsheet_validate "${DRAFT_FILE}" add
    if ! jobsheet_report_validation "requeue of ${FOUND_JOB_ID}"; then
      die "not queued; use --edit to fix the jobsheet"
    fi
  fi
  enqueue_draft "$(meta_get "${FOUND_JOB_DIR}" title "${FOUND_JOB_ID}")" "${FOUND_JOB_ID}"
}

# headrun pause: stop claiming new jobs (the current job finishes).
cmd_pause() {
  queue_ensure_dirs
  printf '%s\n' "$(now_epoch)" > "${PAUSED_FLAG_FILE}"
  local RUNNING_JOB_ID
  RUNNING_JOB_ID="$(queue_running_job_id)"
  if [[ -n "${RUNNING_JOB_ID}" ]]; then
    log_info "paused; the current job (${RUNNING_JOB_ID}) will finish first"
  else
    log_info "paused"
  fi
}

# headrun resume: allow the runner to claim jobs again.
cmd_resume() {
  if [[ -f "${PAUSED_FLAG_FILE}" ]]; then
    rm -f "${PAUSED_FLAG_FILE}"
    log_info "resumed"
  else
    log_info "the queue was not paused"
  fi
  if ! runner_is_active; then
    log_info "note: no runner is active (headrun run)"
  fi
}

# headrun stop: ask the runner to exit after the current job, or kill the job with --now.
cmd_stop() {
  local STOP_NOW=0
  if [[ "${1:-}" == "--now" ]]; then
    STOP_NOW=1
  elif [[ -n "${1:-}" ]]; then
    die "unknown stop option: $1"
  fi
  if ! runner_is_active; then
    die "no runner is active"
  fi
  local RUNNER_PROCESS_ID
  RUNNER_PROCESS_ID="$(< "${RUNNER_PID_FILE}")"
  if (( STOP_NOW == 1 )); then
    kill -TERM "${RUNNER_PROCESS_ID}"
    log_info "sent SIGTERM to runner ${RUNNER_PROCESS_ID}; the current job will be stopped and marked failed"
  else
    : > "${STOP_FLAG_FILE}"
    log_info "stop requested; runner ${RUNNER_PROCESS_ID} will exit after the current job"
  fi
}

# headrun status: runner state, current job and counts.
cmd_status() {
  queue_ensure_dirs
  printf '%s\n' "$(runner_state_summary)"
  local RUNNING_JOB_ID
  RUNNING_JOB_ID="$(queue_running_job_id)"
  if [[ -n "${RUNNING_JOB_ID}" ]]; then
    local RUNNING_DIR="${JOBS_ROOT}/running/${RUNNING_JOB_ID}"
    local ELAPSED_SECONDS=$(( $(now_epoch) - $(meta_get "${RUNNING_DIR}" started_at "$(now_epoch)") ))
    printf 'current: %s — %s (%s, %s of %s)\n' "${RUNNING_JOB_ID}" "$(meta_get "${RUNNING_DIR}" title)" \
      "$(meta_get "${RUNNING_DIR}" engine '?')" "$(seconds_to_human "${ELAPSED_SECONDS}")" \
      "$(seconds_to_human "$(meta_get "${RUNNING_DIR}" timeout 0)")"
  fi
  local STATE_NAME
  local -a COUNT_PARTS=()
  for STATE_NAME in pending running "done" failed cancelled archive; do
    COUNT_PARTS+=("${STATE_NAME} $(queue_list_jobs "${STATE_NAME}" | wc -l)")
  done
  local COUNT_TEXT
  COUNT_TEXT="$(printf '%s, ' "${COUNT_PARTS[@]}")"
  printf 'jobs: %s\n' "${COUNT_TEXT%, }"
}

# headrun run: run the queue in the foreground, or detach a background runner.
cmd_run() {
  local RUN_ONCE=0
  local WATCH_QUEUE=0
  local DETACH_RUNNER=0
  while (( $# > 0 )); do
    case "$1" in
      --once) RUN_ONCE=1; shift ;;
      --watch) WATCH_QUEUE=1; shift ;;
      --detach|-d) DETACH_RUNNER=1; shift ;;
      --quiet|-q) RUNNER_STREAM_OUTPUT=0; shift ;;
      *) die "unknown run option: $1" ;;
    esac
  done
  if (( RUN_ONCE == 1 && WATCH_QUEUE == 1 )); then
    die "--once and --watch cannot be combined"
  fi

  if (( DETACH_RUNNER == 1 )); then
    queue_ensure_dirs
    if runner_is_active; then
      die "a runner is already active (pid $(< "${RUNNER_PID_FILE}"))"
    fi
    local -a RUN_ARGUMENTS=(run --quiet)
    if (( RUN_ONCE == 1 )); then
      RUN_ARGUMENTS+=(--once)
    fi
    if (( WATCH_QUEUE == 1 )); then
      RUN_ARGUMENTS+=(--watch)
    fi
    rm -f "${RUNNER_PID_FILE}"
    setsid -f "${APP_ROOT}/bin/headrun" "${RUN_ARGUMENTS[@]}" < /dev/null >> "${DATA_ROOT}/runner.out" 2>&1
    local WAIT_ATTEMPTS=0
    while [[ ! -s "${RUNNER_PID_FILE}" ]] && (( WAIT_ATTEMPTS < 30 )); do
      sleep 0.1
      WAIT_ATTEMPTS=$(( WAIT_ATTEMPTS + 1 ))
    done
    if [[ -s "${RUNNER_PID_FILE}" ]]; then
      log_info "runner detached (pid $(< "${RUNNER_PID_FILE}")); headrun status / headrun log -f"
    else
      log_warn "runner did not report a pid; it may have exited immediately (see ${DATA_ROOT}/runner.out and headrun log)"
    fi
    return 0
  fi

  runner_main "${RUN_ONCE}" "${WATCH_QUEUE}"
}

# Archives or deletes finished jobs older than the threshold; call under the queue lock.
prune_locked() {
  local THRESHOLD_SECONDS="$1"
  local DELETE_JOBS="$2"
  local DRY_RUN="$3"
  local CUTOFF_EPOCH=$(( $(now_epoch) - THRESHOLD_SECONDS ))
  local -a PRUNE_STATES=("${FINISHED_STATES[@]}")
  if (( DELETE_JOBS == 1 )); then
    PRUNE_STATES+=(archive)
  fi
  PRUNED_COUNT=0
  local STATE_NAME JOB_ID
  while IFS=$'\t' read -r STATE_NAME JOB_ID; do
    local JOB_DIR="${JOBS_ROOT}/${STATE_NAME}/${JOB_ID}"
    local FINISHED_EPOCH
    FINISHED_EPOCH="$(meta_get "${JOB_DIR}" finished_at 0)"
    if (( FINISHED_EPOCH > CUTOFF_EPOCH )); then
      continue
    fi
    PRUNED_COUNT=$(( PRUNED_COUNT + 1 ))
    if (( DRY_RUN == 1 )); then
      printf 'would %s %s/%s\n' "$( (( DELETE_JOBS == 1 )) && printf delete || printf archive)" "${STATE_NAME}" "${JOB_ID}"
    elif (( DELETE_JOBS == 1 )); then
      rm -rf -- "${JOB_DIR}"
      printf 'deleted %s/%s\n' "${STATE_NAME}" "${JOB_ID}"
    else
      meta_set "${JOB_DIR}" archived_from "${STATE_NAME}"
      mv "${JOB_DIR}" "${JOBS_ROOT}/archive/${JOB_ID}"
      printf 'archived %s/%s\n' "${STATE_NAME}" "${JOB_ID}"
    fi
  done < <(queue_list_jobs "${PRUNE_STATES[@]}")
}

# headrun prune: archive (or delete) finished jobs older than a threshold.
cmd_prune() {
  local THRESHOLD_TEXT="${CFG_PRUNE_AFTER}"
  local DELETE_JOBS=0
  local DRY_RUN=0
  while (( $# > 0 )); do
    case "$1" in
      --older-than) THRESHOLD_TEXT="${2:-}"; shift 2 ;;
      --delete) DELETE_JOBS=1; shift ;;
      -n|--dry-run) DRY_RUN=1; shift ;;
      *) die "unknown prune option: $1" ;;
    esac
  done
  local THRESHOLD_SECONDS
  if ! THRESHOLD_SECONDS="$(duration_to_seconds "${THRESHOLD_TEXT}")"; then
    die "--older-than needs a duration such as 7d or 12h"
  fi
  queue_ensure_dirs
  PRUNED_COUNT=0
  with_queue_lock prune_locked "${THRESHOLD_SECONDS}" "${DELETE_JOBS}" "${DRY_RUN}"
  log_info "${PRUNED_COUNT} job(s) older than ${THRESHOLD_TEXT} $( (( DRY_RUN == 1 )) && printf 'would be ' )$( (( DELETE_JOBS == 1 )) && printf deleted || printf archived)"
}

# Prints one doctor check line.
doctor_line() {
  local CHECK_STATUS="$1"
  local CHECK_MESSAGE="$2"
  local STATUS_COLOUR=""
  case "${CHECK_STATUS}" in
    ok) STATUS_COLOUR="${COLOUR_GREEN}" ;;
    warn) STATUS_COLOUR="${COLOUR_YELLOW}" ;;
    fail) STATUS_COLOUR="${COLOUR_RED}" ;;
    *) STATUS_COLOUR="${COLOUR_DIM}" ;;
  esac
  printf '  %s%-4s%s %s\n' "${STATUS_COLOUR}" "${CHECK_STATUS}" "${COLOUR_RESET}" "${CHECK_MESSAGE}"
}

# headrun doctor: check dependencies, paths, configuration and engines.
cmd_doctor() {
  local FAILURE_COUNT=0
  printf 'headrun %s (%s)\n\nDependencies\n' "${HEADRUN_VERSION}" "${APP_ROOT}"
  doctor_line ok "bash ${BASH_VERSION}"
  local REQUIRED_COMMAND
  for REQUIRED_COMMAND in flock setsid timeout awk tail sort mktemp; do
    if command -v "${REQUIRED_COMMAND}" > /dev/null; then
      doctor_line ok "${REQUIRED_COMMAND}"
    else
      doctor_line fail "${REQUIRED_COMMAND} not found (required)"
      FAILURE_COUNT=$(( FAILURE_COUNT + 1 ))
    fi
  done
  if command -v jq > /dev/null; then
    doctor_line ok "jq (optional: readable Claude transcripts, response fallback)"
  else
    doctor_line warn "jq not found (optional: without it Claude transcripts are raw JSON)"
  fi

  printf '\nPaths\n'
  if [[ -f "${CONFIG_FILE}" ]]; then
    doctor_line ok "config ${CONFIG_FILE}"
  else
    doctor_line info "config ${CONFIG_FILE} (absent; using defaults — see ${APP_ROOT}/share/config.sample)"
  fi
  queue_ensure_dirs
  local DATA_PERMISSIONS
  DATA_PERMISSIONS="$(stat -c '%a' "${DATA_ROOT}")"
  if [[ "${DATA_PERMISSIONS}" == "700" ]]; then
    doctor_line ok "data ${DATA_ROOT} (mode 700)"
  else
    doctor_line warn "data ${DATA_ROOT} is mode ${DATA_PERMISSIONS}; anyone who can write jobs can run commands as $(id -un) (chmod 700 recommended)"
  fi
  local GUIDE_NAME
  for GUIDE_NAME in preamble.md safety.md; do
    if [[ -f "${CONFIG_DIR}/${GUIDE_NAME}" ]]; then
      doctor_line ok "${GUIDE_NAME}: ${CONFIG_DIR}/${GUIDE_NAME}"
    else
      doctor_line info "${GUIDE_NAME}: built-in (copy ${APP_ROOT}/share/${GUIDE_NAME} to ${CONFIG_DIR}/ to customise)"
    fi
  done
  local LOCAL_BIN_DIR="${USER_HOME}/.local/bin"
  if [[ ":${CURRENT_SEARCH_PATH}:" == *":${LOCAL_BIN_DIR}:"* ]]; then
    doctor_line ok "${LOCAL_BIN_DIR} is on PATH"
  else
    doctor_line warn "${LOCAL_BIN_DIR} is not on PATH"
  fi

  printf '\nEngines\n'
  if [[ -n "${CFG_DEFAULT_ENGINE}" ]]; then
    if [[ -n "$(engine_adapter_path "${CFG_DEFAULT_ENGINE}")" ]]; then
      doctor_line ok "default engine: ${CFG_DEFAULT_ENGINE}"
    else
      doctor_line fail "default engine ${CFG_DEFAULT_ENGINE} has no adapter"
      FAILURE_COUNT=$(( FAILURE_COUNT + 1 ))
    fi
  else
    doctor_line info "no default engine; jobsheets must name one"
  fi
  local ENGINE_NAME
  while IFS= read -r ENGINE_NAME; do
    local ADAPTER_PATH CHECK_OUTPUT
    ADAPTER_PATH="$(engine_adapter_path "${ENGINE_NAME}")"
    if CHECK_OUTPUT="$(HEADRUN_ENGINE_BIN="$(config_engine_bin "${ENGINE_NAME}")" HEADRUN_APP_ROOT="${APP_ROOT}" bash "${ADAPTER_PATH}" check 2>&1)"; then
      doctor_line ok "${ENGINE_NAME}: ${CHECK_OUTPUT}"
    else
      doctor_line warn "${ENGINE_NAME}: ${CHECK_OUTPUT:-unavailable}"
    fi
  done < <(engine_list_names)

  printf '\nRunner\n'
  doctor_line info "$(runner_state_summary)"
  if command -v loginctl > /dev/null; then
    local LINGER_STATE=""
    if ! LINGER_STATE="$(loginctl show-user "$(id -un)" --property=Linger --value 2>&1)"; then
      doctor_line warn "could not query systemd linger state: ${LINGER_STATE}"
      LINGER_STATE="unknown"
    fi
    if [[ "${LINGER_STATE}" == "yes" ]]; then
      doctor_line ok "systemd linger enabled (user services survive logout)"
    else
      doctor_line info "systemd linger: ${LINGER_STATE} (needed for install-service on a headless account: sudo loginctl enable-linger $(id -un))"
    fi
  fi

  printf '\n'
  if (( FAILURE_COUNT > 0 )); then
    die "${FAILURE_COUNT} required check(s) failed"
  fi
  log_info "all required checks passed"
}

# headrun install-service: write (and optionally enable) a systemd user unit for the runner.
cmd_install_service() {
  local ENABLE_SERVICE=0
  if [[ "${1:-}" == "--enable" ]]; then
    ENABLE_SERVICE=1
  elif [[ -n "${1:-}" ]]; then
    die "unknown install-service option: $1"
  fi
  local UNIT_DIRECTORY="${USER_HOME}/.config/systemd/user"
  local UNIT_FILE="${UNIT_DIRECTORY}/headrun.service"
  mkdir -p "${UNIT_DIRECTORY}"
  cat > "${UNIT_FILE}" <<EOF
# Generated by headrun ${HEADRUN_VERSION} (headrun install-service)
[Unit]
Description=head-runner job queue (headrun run --watch)
After=network-online.target

[Service]
Type=simple
ExecStart=${APP_ROOT}/bin/headrun run --watch --quiet
Environment=PATH=${CURRENT_SEARCH_PATH}
Restart=on-failure
RestartSec=30
KillMode=mixed
TimeoutStopSec=90

[Install]
WantedBy=default.target
EOF
  log_info "wrote ${UNIT_FILE}"
  if (( ENABLE_SERVICE == 1 )); then
    systemctl --user daemon-reload
    systemctl --user enable --now headrun.service
    log_info "enabled and started headrun.service (systemctl --user status headrun)"
  else
    log_info "enable it with: systemctl --user daemon-reload && systemctl --user enable --now headrun.service"
  fi
  log_info "on a headless account also run (as root): loginctl enable-linger $(id -un)"
}

# Dispatches the command line to a subcommand.
main() {
  config_read_environment "${HEADRUN_ENTRY_SCRIPT}"
  local COMMAND_NAME="${1:-help}"
  if (( $# > 0 )); then
    shift
  fi
  case "${COMMAND_NAME}" in
    help|-h|--help) cmd_help ;;
    version|-V|--version) cmd_version ;;
    *)
      config_load
      if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        COMMAND_NAME="help"
      fi
      case "${COMMAND_NAME}" in
        help) cmd_help ;;
        add) cmd_add "$@" ;;
        new) cmd_new "$@" ;;
        ls|list) cmd_ls "$@" ;;
        show) cmd_show "$@" ;;
        tail) cmd_tail "$@" ;;
        log) cmd_log "$@" ;;
        edit) cmd_edit "$@" ;;
        bump) cmd_bump "$@" ;;
        cancel) cmd_cancel "$@" ;;
        requeue) cmd_requeue "$@" ;;
        run) cmd_run "$@" ;;
        pause) cmd_pause "$@" ;;
        resume) cmd_resume "$@" ;;
        stop) cmd_stop "$@" ;;
        status) cmd_status "$@" ;;
        prune) cmd_prune "$@" ;;
        doctor) cmd_doctor "$@" ;;
        install-service) cmd_install_service "$@" ;;
        *) die "unknown command \"${COMMAND_NAME}\" (headrun help)" ;;
      esac
      ;;
  esac
}
