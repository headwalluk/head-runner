# shellcheck shell=bash
# Regression tests for defects found in the pre-1.0 review.

test_claim_survives_a_large_queue() {
  local TEMPLATE_ID
  TEMPLATE_ID="$(add_stub_job "Template")"
  local COPY_NUMBER
  for COPY_NUMBER in $(seq 1 200); do
    cp -r "${HEADRUN_HOME}/jobs/pending/${TEMPLATE_ID}" "${HEADRUN_HOME}/jobs/pending/${TEMPLATE_ID}-copy-${COPY_NUMBER}"
  done
  local RUN_NUMBER
  for RUN_NUMBER in 1 2 3 4 5; do
    headrun run --once > /dev/null 2>&1 || fail "run --once ${RUN_NUMBER} exited with status $?"
  done
  assert_equals 5 "$(headrun ls -q --state "done" | wc -l)"
}

test_timeout_kills_descendants_that_ignore_sigterm() {
  local TICKS_FILE="${TEST_SANDBOX_ROOT}/ticks"
  printf -- '---\nengine: shell\nworkdir: %s\ntimeout: 2s\ncommand: trap "" TERM; while true; do date +%%s%%N >> %s; sleep 0.2; done\n---\nBody\n' \
    "${TEST_WORKDIR}" "${TICKS_FILE}" | headrun add - > /dev/null 2>&1
  headrun run > /dev/null 2>&1
  local TICKS_AFTER_RUN
  TICKS_AFTER_RUN="$(wc -l < "${TICKS_FILE}")"
  sleep 1.5
  assert_equals "${TICKS_AFTER_RUN}" "$(wc -l < "${TICKS_FILE}")" "ticks after the runner moved on"
}

runner_pid_alive() { [[ -s "${HEADRUN_HOME}/runner.pid" ]] && kill -0 "$(< "${HEADRUN_HOME}/runner.pid")" 2>/dev/null; }
job_in_state() { [[ "$(job_state_of "$1")" == "$2" ]]; }

test_killed_streaming_runner_does_not_leave_the_lock_held() {
  local SLOW_ID
  SLOW_ID="$(add_stub_job "Slow" "stub_sleep: 30")"
  "${REPOSITORY_ROOT}/bin/headrun" run > /dev/null 2>&1 &
  local RUNNER_PROCESS_ID=$!
  wait_for 10 job_in_state "${SLOW_ID}" running
  kill -KILL "${RUNNER_PROCESS_ID}"
  local KILLED_STATUS=0
  wait "${RUNNER_PROCESS_ID}" || KILLED_STATUS=$?
  assert_equals 137 "${KILLED_STATUS}" "killed runner status"
  local COMMAND_OUTPUT
  COMMAND_OUTPUT="$(headrun run 2>&1)" || fail "a new runner should start after kill -9: ${COMMAND_OUTPUT}"
  assert_equals failed "$(job_state_of "${SLOW_ID}")"
  assert_contains "$(job_meta "${SLOW_ID}" reason)" "orphaned"
}

test_bad_workdir_fails_one_job_not_the_runner() {
  local BAD_ID GOOD_ID
  BAD_ID="$(printf -- '---\nengine: stub\nworkdir: %s/becomes-a-file\ncreate_workdir: yes\n---\nBody\n' "${TEST_SANDBOX_ROOT}" | headrun add - 2>/dev/null)"
  GOOD_ID="$(add_stub_job "Good")"
  printf 'not a directory\n' > "${TEST_SANDBOX_ROOT}/becomes-a-file"
  headrun run > /dev/null 2>&1 || fail "runner should survive a bad workdir"
  assert_equals failed "$(job_state_of "${BAD_ID}")"
  assert_contains "$(job_meta "${BAD_ID}" reason)" "not a directory"
  assert_equals "done" "$(job_state_of "${GOOD_ID}")"
}

test_option_values_with_hash_and_backslash_survive() {
  local JOB_ID
  JOB_ID="$(printf 'Body\n' | headrun add -e stub -w "${TEST_WORKDIR}" --title 'Fix #42 regex \d+' - 2>/dev/null)"
  assert_equals 'Fix #42 regex \d+' "$(job_meta "${JOB_ID}" title)"
  local COMMAND_OUTPUT
  if COMMAND_OUTPUT="$(printf 'Body\n' | headrun add -e stub -w "${TEST_WORKDIR}" --title $'tab\there' - 2>&1)"; then
    fail "a tab in an option value should be rejected"
  fi
  assert_contains "${COMMAND_OUTPUT}" "tabs or line breaks"
}

test_idle_runner_exits_cleanly_on_sigterm() {
  "${REPOSITORY_ROOT}/bin/headrun" run --watch > /dev/null 2>&1 &
  local RUNNER_PROCESS_ID=$!
  wait_for 10 runner_pid_alive
  kill -TERM "${RUNNER_PROCESS_ID}"
  local RUNNER_STATUS=0
  wait "${RUNNER_PROCESS_ID}" || RUNNER_STATUS=$?
  assert_equals 0 "${RUNNER_STATUS}" "runner exit status"
}

test_zero_kill_grace_is_rejected() {
  printf 'KILL_GRACE=0\n' >> "${HEADRUN_CONFIG_DIR}/config"
  local COMMAND_OUTPUT
  if COMMAND_OUTPUT="$(headrun ls 2>&1)"; then fail "KILL_GRACE=0 should be rejected"; fi
  assert_contains "${COMMAND_OUTPUT}" "KILL_GRACE must be a positive duration"
}

test_ls_columns_align_with_long_ids() {
  add_stub_job "Short" > /dev/null
  add_stub_job "A rather long job title that makes a long slug" > /dev/null
  local PRIORITY_OFFSETS
  PRIORITY_OFFSETS="$(headrun ls | awk 'NR > 2 { print index($0, " 50  ") }' | sort -u)"
  assert_equals 1 "$(printf '%s\n' "${PRIORITY_OFFSETS}" | wc -l)" "distinct PRI column offsets"
}
