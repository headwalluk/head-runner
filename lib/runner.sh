# shellcheck shell=bash
# Runner: claims pending jobs one at a time, runs the engine adapter, and records the outcome.

RUNNER_LOCK_FD=""
RUNNER_STREAM_OUTPUT=1
RUNNER_STOP_REQUESTED=0
RUNNER_SIGNAL_COUNT=0
ACTIVE_JOB_PROCESS_ID=""
ACTIVE_JOB_STOP_REASON=""
CLAIMED_JOB_ID=""

# Acquires the runner lock without waiting; dies if another runner holds it.
runner_acquire_lock() {
  exec {RUNNER_LOCK_FD}>>"${RUNNER_LOCK_FILE}"
  if ! flock --nonblock "${RUNNER_LOCK_FD}"; then
    local OTHER_RUNNER_ID=""
    if [[ -f "${RUNNER_PID_FILE}" ]]; then
      OTHER_RUNNER_ID="$(< "${RUNNER_PID_FILE}")"
    fi
    die "a runner is already active${OTHER_RUNNER_ID:+ (pid ${OTHER_RUNNER_ID})}"
  fi
  printf '%s\n' "$$" > "${RUNNER_PID_FILE}"
}

# Returns 0 if a runner currently holds the runner lock.
runner_is_active() {
  local PROBE_LOCK_FD
  local RUNNER_ACTIVE=1
  if [[ -f "${RUNNER_LOCK_FILE}" ]]; then
    exec {PROBE_LOCK_FD}>>"${RUNNER_LOCK_FILE}"
    if flock --nonblock "${PROBE_LOCK_FD}"; then
      RUNNER_ACTIVE=1
    else
      RUNNER_ACTIVE=0
    fi
    exec {PROBE_LOCK_FD}>&-
  fi
  return "${RUNNER_ACTIVE}"
}

# Handles INT/TERM/HUP: stops the active job (escalating to SIGKILL on repeat) and ends the run loop.
runner_on_signal() {
  local SIGNAL_NAME="$1"
  RUNNER_SIGNAL_COUNT=$(( RUNNER_SIGNAL_COUNT + 1 ))
  RUNNER_STOP_REQUESTED=1
  if [[ -n "${ACTIVE_JOB_PROCESS_ID}" ]] && process_is_alive "${ACTIVE_JOB_PROCESS_ID}"; then
    if (( RUNNER_SIGNAL_COUNT == 1 )); then
      ACTIVE_JOB_STOP_REASON="stopped by SIG${SIGNAL_NAME}"
      log_warn "received SIG${SIGNAL_NAME}: stopping job ${CLAIMED_JOB_ID} (send again to force)"
      kill -TERM -- "-${ACTIVE_JOB_PROCESS_ID}" 2>/dev/null || log_warn "job process group ${ACTIVE_JOB_PROCESS_ID} already gone"
    else
      log_warn "received SIG${SIGNAL_NAME} again: killing job ${CLAIMED_JOB_ID}"
      kill -KILL -- "-${ACTIVE_JOB_PROCESS_ID}" 2>/dev/null || log_warn "job process group ${ACTIVE_JOB_PROCESS_ID} already gone"
    fi
  else
    log_info "received SIG${SIGNAL_NAME}: runner exiting"
    exit 130
  fi
}

# Removes the runner pid file on exit.
runner_cleanup() {
  if [[ -f "${RUNNER_PID_FILE}" && "$(< "${RUNNER_PID_FILE}")" == "$$" ]]; then
    rm -f "${RUNNER_PID_FILE}"
  fi
}

# Moves jobs left in running/ by a dead runner to failed/, killing any surviving engine process group.
runner_recover_orphans() {
  local STATE_NAME JOB_ID
  while IFS=$'\t' read -r STATE_NAME JOB_ID; do
    local JOB_DIR="${JOBS_ROOT}/running/${JOB_ID}"
    local ORPHAN_PROCESS_ID
    ORPHAN_PROCESS_ID="$(meta_get "${JOB_DIR}" pid)"
    if process_is_alive "${ORPHAN_PROCESS_ID}"; then
      log_warn "orphaned job ${JOB_ID}: engine process group ${ORPHAN_PROCESS_ID} still alive, terminating"
      kill -TERM -- "-${ORPHAN_PROCESS_ID}" 2>/dev/null || log_warn "could not signal process group ${ORPHAN_PROCESS_ID}"
    fi
    log_warn "orphaned job ${JOB_ID}: its runner exited without finishing it; marking as failed"
    runner_finalise_job "${JOB_DIR}" failed "orphaned: the runner exited while the job was running" ""
  done < <(queue_list_jobs running)
}

# Moves the next pending job to running/ and sets CLAIMED_JOB_ID (empty if the queue is empty); call under the queue lock.
runner_claim_next_locked() {
  CLAIMED_JOB_ID="$(queue_pending_in_order | head -n 1)"
  if [[ -n "${CLAIMED_JOB_ID}" ]]; then
    mv "${JOBS_ROOT}/pending/${CLAIMED_JOB_ID}" "${JOBS_ROOT}/running/${CLAIMED_JOB_ID}"
  fi
}

# Moves a job directory from running/ to its final state; call under the queue lock.
runner_move_job_locked() {
  local JOB_ID="$1"
  local FINAL_STATE="$2"
  mv "${JOBS_ROOT}/running/${JOB_ID}" "${JOBS_ROOT}/${FINAL_STATE}/${JOB_ID}"
}

# Writes the composed prompt (preamble, safety guide, job context, request body) to the job directory.
runner_compose_prompt() {
  local JOB_DIR="$1"
  local WORKDIR_PATH="$2"
  local EXTRA_DIRECTORIES="$3"
  local GUIDE_NAME GUIDE_PATH
  {
    for GUIDE_NAME in preamble.md safety.md; do
      GUIDE_PATH="${CONFIG_DIR}/${GUIDE_NAME}"
      if [[ ! -f "${GUIDE_PATH}" ]]; then
        GUIDE_PATH="${APP_ROOT}/share/${GUIDE_NAME}"
      fi
      if [[ -f "${GUIDE_PATH}" ]]; then
        cat "${GUIDE_PATH}"
        printf '\n'
      fi
    done
    printf '## Job context\n\n'
    printf -- '- Job ID: %s\n' "${JOB_DIR##*/}"
    printf -- '- Working directory: %s\n' "${WORKDIR_PATH}"
    if [[ -n "${EXTRA_DIRECTORIES}" ]]; then
      printf -- '- Additional directories: %s\n' "${EXTRA_DIRECTORIES}"
    fi
    printf -- '- Response file (write your final Markdown response here): %s\n' "${JOB_DIR}/response.md"
    printf -- '- Original jobsheet: %s\n' "${JOB_DIR}/request.md"
    printf '\n---\n\n# Request\n\n'
    frontmatter_body "${JOB_DIR}/request.md"
  } > "${JOB_DIR}/prompt.md"
}

# Prints the outcome declared on an "Outcome:" line near the top of a response (completed, partial, blocked), or nothing.
runner_response_outcome() {
  local RESPONSE_FILE="$1"
  awk '
    NR > 15 { exit }
    {
      line = tolower($0)
      gsub(/[*_`>#]/, "", line)
      if (match(line, /^[ \t]*outcome[ \t]*:[ \t]*(completed|partial|blocked)/)) {
        sub(/^[ \t]*outcome[ \t]*:[ \t]*/, "", line)
        sub(/[^a-z].*$/, "", line)
        print line
        exit
      }
    }
  ' "${RESPONSE_FILE}"
}

# Ensures response.md exists, prepends the runner frontmatter, records meta, and moves the job to done/ or failed/.
runner_finalise_job() {
  local JOB_DIR="$1"
  local PROPOSED_STATE="$2"
  local FAILURE_REASON="$3"
  local EXIT_CODE="$4"
  local JOB_ID="${JOB_DIR##*/}"
  local RESPONSE_FILE="${JOB_DIR}/response.md"
  local FINISHED_EPOCH
  FINISHED_EPOCH="$(now_epoch)"

  if [[ ! -s "${RESPONSE_FILE}" ]]; then
    {
      printf '# No response written\n\n'
      if [[ -n "${FAILURE_REASON}" ]]; then
        printf 'The job did not complete: %s.\n\n' "${FAILURE_REASON}"
      else
        printf 'The engine exited successfully but did not write a response.\n\n'
      fi
      if [[ -s "${JOB_DIR}/transcript.log" ]]; then
        printf 'Last 40 lines of `transcript.log`:\n\n```text\n'
        tail -n 40 "${JOB_DIR}/transcript.log"
        printf '```\n'
      fi
    } > "${RESPONSE_FILE}"
    meta_set "${JOB_DIR}" response_source runner
  else
    meta_set "${JOB_DIR}" response_source engine
  fi

  local FINAL_STATE="${PROPOSED_STATE}"
  local RESPONSE_OUTCOME
  RESPONSE_OUTCOME="$(runner_response_outcome "${RESPONSE_FILE}")"
  if [[ "${FINAL_STATE}" == "done" && ( "${RESPONSE_OUTCOME}" == "blocked" || "${RESPONSE_OUTCOME}" == "partial" ) ]]; then
    FINAL_STATE="failed"
    FAILURE_REASON="the agent reported the outcome as ${RESPONSE_OUTCOME}"
  fi

  local STARTED_EPOCH
  STARTED_EPOCH="$(meta_get "${JOB_DIR}" started_at "${FINISHED_EPOCH}")"
  meta_set "${JOB_DIR}" finished_at "${FINISHED_EPOCH}"
  meta_set "${JOB_DIR}" exit_code "${EXIT_CODE}"
  meta_set "${JOB_DIR}" outcome "${RESPONSE_OUTCOME:-unknown}"
  meta_set "${JOB_DIR}" reason "${FAILURE_REASON}"

  local RESPONSE_BODY_FILE="${RESPONSE_FILE}.body.$$"
  mv "${RESPONSE_FILE}" "${RESPONSE_BODY_FILE}"
  {
    printf -- '---\n'
    printf 'job: %s\n' "${JOB_ID}"
    printf 'title: %s\n' "$(meta_get "${JOB_DIR}" title)"
    printf 'status: %s\n' "${FINAL_STATE}"
    printf 'outcome: %s\n' "${RESPONSE_OUTCOME:-unknown}"
    if [[ -n "${FAILURE_REASON}" ]]; then
      printf 'reason: %s\n' "${FAILURE_REASON}"
    fi
    printf 'engine: %s\n' "$(meta_get "${JOB_DIR}" engine)"
    local OPTIONAL_KEY
    for OPTIONAL_KEY in model workdir session_id cost_usd num_turns; do
      local OPTIONAL_VALUE
      OPTIONAL_VALUE="$(meta_get "${JOB_DIR}" "${OPTIONAL_KEY}")"
      if [[ -n "${OPTIONAL_VALUE}" ]]; then
        printf '%s: %s\n' "${OPTIONAL_KEY}" "${OPTIONAL_VALUE}"
      fi
    done
    printf 'started: %s\n' "$(epoch_to_iso "${STARTED_EPOCH}")"
    printf 'finished: %s\n' "$(epoch_to_iso "${FINISHED_EPOCH}")"
    printf 'duration: %s\n' "$(seconds_to_human $(( FINISHED_EPOCH - STARTED_EPOCH )))"
    printf 'exit_code: %s\n' "${EXIT_CODE:-none}"
    printf -- '---\n\n'
    cat "${RESPONSE_BODY_FILE}"
  } > "${RESPONSE_FILE}"
  rm -f "${RESPONSE_BODY_FILE}"

  with_queue_lock runner_move_job_locked "${JOB_ID}" "${FINAL_STATE}"

  local DURATION_TEXT
  DURATION_TEXT="$(seconds_to_human $(( FINISHED_EPOCH - STARTED_EPOCH )))"
  if [[ "${FINAL_STATE}" == "done" ]]; then
    log_info "job ${JOB_ID}: done in ${DURATION_TEXT}"
  else
    log_warn "job ${JOB_ID}: failed after ${DURATION_TEXT}: ${FAILURE_REASON}"
  fi
}

# Copies selected key=value lines from the adapter's engine.meta file into the job meta.
runner_merge_engine_meta() {
  local JOB_DIR="$1"
  local ENGINE_META_FILE="${JOB_DIR}/engine.meta"
  if [[ -f "${ENGINE_META_FILE}" ]]; then
    local META_LINE
    while IFS= read -r META_LINE; do
      if [[ "${META_LINE}" =~ ^(session_id|cost_usd|num_turns|engine_version|engine_note)=(.*)$ ]]; then
        meta_set "${JOB_DIR}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
      fi
    done < "${ENGINE_META_FILE}"
  fi
}

# Runs one claimed job from running/ through its engine adapter and finalises it.
runner_run_job() {
  local JOB_ID="$1"
  local JOB_DIR="${JOBS_ROOT}/running/${JOB_ID}"
  local REQUEST_FILE="${JOB_DIR}/request.md"

  meta_set "${JOB_DIR}" started_at "$(now_epoch)"
  meta_set "${JOB_DIR}" runner_pid "$$"
  meta_set "${JOB_DIR}" host "$(hostname 2>/dev/null || printf 'unknown')"
  log_info "job ${JOB_ID}: started ($(meta_get "${JOB_DIR}" title))"

  jobsheet_validate "${REQUEST_FILE}" run
  if (( ${#VALIDATION_ERRORS[@]} > 0 )); then
    local VALIDATION_SUMMARY
    VALIDATION_SUMMARY="$(printf '%s; ' "${VALIDATION_ERRORS[@]}")"
    {
      printf '# Job rejected\n\nThe jobsheet failed validation when the runner picked it up:\n\n'
      printf -- '- %s\n' "${VALIDATION_ERRORS[@]}"
    } > "${JOB_DIR}/response.md"
    runner_finalise_job "${JOB_DIR}" failed "invalid jobsheet: ${VALIDATION_SUMMARY%; }" ""
    return 0
  fi

  local -A JOB_FIELDS=()
  local -a PARSE_PROBLEMS=()
  frontmatter_load "${REQUEST_FILE}" JOB_FIELDS PARSE_PROBLEMS

  local ENGINE_NAME="${JOB_FIELDS[engine]:-${CFG_DEFAULT_ENGINE}}"
  local ADAPTER_PATH
  ADAPTER_PATH="$(engine_adapter_path "${ENGINE_NAME}")"
  local WORKDIR_PATH="${JOB_FIELDS[workdir]:-${CFG_DEFAULT_WORKDIR}}"
  local TIMEOUT_SECONDS="${DEFAULT_TIMEOUT_SECONDS}"
  if [[ -n "${JOB_FIELDS[timeout]:-}" ]]; then
    TIMEOUT_SECONDS="$(duration_to_seconds "${JOB_FIELDS[timeout]}")"
  fi
  local PERMISSION_MODE="${JOB_FIELDS[permissions]:-${CFG_DEFAULT_PERMISSIONS}}"
  local EXTRA_DIRECTORIES="${JOB_FIELDS[dirs]:-}"

  if [[ ! -d "${WORKDIR_PATH}" ]]; then
    mkdir -p "${WORKDIR_PATH}"
    log_info "job ${JOB_ID}: created workdir ${WORKDIR_PATH}"
  fi

  meta_set "${JOB_DIR}" engine "${ENGINE_NAME}"
  meta_set "${JOB_DIR}" model "${JOB_FIELDS[model]:-}"
  meta_set "${JOB_DIR}" workdir "${WORKDIR_PATH}"
  meta_set "${JOB_DIR}" timeout "${TIMEOUT_SECONDS}"
  meta_set "${JOB_DIR}" permissions "${PERMISSION_MODE}"

  runner_compose_prompt "${JOB_DIR}" "${WORKDIR_PATH}" "${EXTRA_DIRECTORIES}"
  : > "${JOB_DIR}/transcript.log"

  local -a ADAPTER_ENVIRONMENT=(
    "HEADRUN_JOB_ID=${JOB_ID}"
    "HEADRUN_JOB_DIR=${JOB_DIR}"
    "HEADRUN_REQUEST=${REQUEST_FILE}"
    "HEADRUN_PROMPT=${JOB_DIR}/prompt.md"
    "HEADRUN_RESPONSE=${JOB_DIR}/response.md"
    "HEADRUN_ENGINE_META=${JOB_DIR}/engine.meta"
    "HEADRUN_WORKDIR=${WORKDIR_PATH}"
    "HEADRUN_DIRS=${EXTRA_DIRECTORIES}"
    "HEADRUN_ENGINE=${ENGINE_NAME}"
    "HEADRUN_ENGINE_BIN=$(config_engine_bin "${ENGINE_NAME}")"
    "HEADRUN_MODEL=${JOB_FIELDS[model]:-}"
    "HEADRUN_PERMISSIONS=${PERMISSION_MODE}"
    "HEADRUN_TIMEOUT=${TIMEOUT_SECONDS}"
    "HEADRUN_TITLE=$(meta_get "${JOB_DIR}" title)"
    "HEADRUN_APP_ROOT=${APP_ROOT}"
  )
  local FIELD_KEY
  for FIELD_KEY in "${!JOB_FIELDS[@]}"; do
    ADAPTER_ENVIRONMENT+=("HEADRUN_FM_${FIELD_KEY^^}=${JOB_FIELDS[${FIELD_KEY}]}")
  done

  log_info "job ${JOB_ID}: engine ${ENGINE_NAME}${JOB_FIELDS[model]:+ (${JOB_FIELDS[model]})}, timeout $(seconds_to_human "${TIMEOUT_SECONDS}"), workdir ${WORKDIR_PATH}"

  ACTIVE_JOB_STOP_REASON=""
  (
    cd "${WORKDIR_PATH}"
    exec env "${ADAPTER_ENVIRONMENT[@]}" setsid timeout --signal=TERM --kill-after="${KILL_GRACE_SECONDS}" "${TIMEOUT_SECONDS}" bash "${ADAPTER_PATH}" run
  ) < /dev/null >> "${JOB_DIR}/transcript.log" 2>&1 {RUNNER_LOCK_FD}>&- &
  ACTIVE_JOB_PROCESS_ID=$!
  meta_set "${JOB_DIR}" pid "${ACTIVE_JOB_PROCESS_ID}"

  local TAIL_PROCESS_ID=""
  if (( RUNNER_STREAM_OUTPUT == 1 )); then
    tail -n +1 -f --pid="${ACTIVE_JOB_PROCESS_ID}" "${JOB_DIR}/transcript.log" &
    TAIL_PROCESS_ID=$!
  fi

  local JOB_EXIT_CODE=0
  while process_is_alive "${ACTIVE_JOB_PROCESS_ID}"; do
    JOB_EXIT_CODE=0
    wait "${ACTIVE_JOB_PROCESS_ID}" || JOB_EXIT_CODE=$?
  done
  JOB_EXIT_CODE=0
  wait "${ACTIVE_JOB_PROCESS_ID}" || JOB_EXIT_CODE=$?
  ACTIVE_JOB_PROCESS_ID=""

  if [[ -n "${TAIL_PROCESS_ID}" ]]; then
    wait "${TAIL_PROCESS_ID}" || log_debug "transcript tail exited with status $?"
  fi

  runner_merge_engine_meta "${JOB_DIR}"

  local PROPOSED_STATE="done"
  local FAILURE_REASON=""
  if [[ -n "${ACTIVE_JOB_STOP_REASON}" ]]; then
    PROPOSED_STATE="failed"
    FAILURE_REASON="${ACTIVE_JOB_STOP_REASON}"
  elif (( JOB_EXIT_CODE == 124 )); then
    PROPOSED_STATE="failed"
    FAILURE_REASON="timed out after $(seconds_to_human "${TIMEOUT_SECONDS}")"
  elif (( JOB_EXIT_CODE == 137 )); then
    PROPOSED_STATE="failed"
    FAILURE_REASON="killed after ignoring the timeout signal for $(seconds_to_human "${KILL_GRACE_SECONDS}")"
  elif (( JOB_EXIT_CODE != 0 )); then
    PROPOSED_STATE="failed"
    FAILURE_REASON="engine exited with status ${JOB_EXIT_CODE}"
  fi

  runner_finalise_job "${JOB_DIR}" "${PROPOSED_STATE}" "${FAILURE_REASON}" "${JOB_EXIT_CODE}"
}

# Main run loop: drains the queue (or watches it), honouring pause and stop requests.
runner_main() {
  local RUN_ONCE="$1"
  local WATCH_QUEUE="$2"

  queue_ensure_dirs
  runner_acquire_lock
  LOG_FILE="${HEADRUN_LOG_PATH}"
  LOG_WITH_TIMESTAMPS=1
  trap runner_cleanup EXIT
  trap 'runner_on_signal INT' INT
  trap 'runner_on_signal TERM' TERM
  trap 'runner_on_signal HUP' HUP

  rm -f "${STOP_FLAG_FILE}"
  log_info "runner started (pid $$, headrun ${HEADRUN_VERSION}, $( (( WATCH_QUEUE == 1 )) && printf 'watching' || printf 'draining') ${JOBS_ROOT})"
  runner_recover_orphans

  local JOBS_RUN=0
  local IDLE_NOTICE_SHOWN=0
  while (( RUNNER_STOP_REQUESTED == 0 )); do
    if [[ -f "${STOP_FLAG_FILE}" ]]; then
      rm -f "${STOP_FLAG_FILE}"
      log_info "stop requested: runner exiting"
      break
    fi

    if [[ -f "${PAUSED_FLAG_FILE}" ]]; then
      if (( WATCH_QUEUE == 0 )); then
        log_info "queue is paused (headrun resume): runner exiting"
        break
      fi
      if (( IDLE_NOTICE_SHOWN != 1 )); then
        log_info "queue is paused; waiting for headrun resume"
        IDLE_NOTICE_SHOWN=1
      fi
      interruptible_sleep "${POLL_INTERVAL_SECONDS}"
      continue
    fi

    with_queue_lock runner_claim_next_locked
    if [[ -z "${CLAIMED_JOB_ID}" ]]; then
      if (( WATCH_QUEUE == 0 )); then
        log_info "queue is empty: runner exiting after ${JOBS_RUN} job(s)"
        break
      fi
      if (( IDLE_NOTICE_SHOWN != 2 )); then
        log_info "queue is empty; watching for new jobs"
        IDLE_NOTICE_SHOWN=2
      fi
      interruptible_sleep "${POLL_INTERVAL_SECONDS}"
      continue
    fi

    IDLE_NOTICE_SHOWN=0
    runner_run_job "${CLAIMED_JOB_ID}"
    CLAIMED_JOB_ID=""
    JOBS_RUN=$(( JOBS_RUN + 1 ))
    if (( RUN_ONCE == 1 )); then
      break
    fi
  done

  if (( RUNNER_STOP_REQUESTED == 1 )); then
    log_info "runner stopped by signal after ${JOBS_RUN} job(s)"
  fi
}
