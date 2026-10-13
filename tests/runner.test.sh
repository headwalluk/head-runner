# shellcheck shell=bash
# Runner tests: outcomes, failures, timeouts, pause/stop, locking and orphan recovery.

test_run_success_writes_response_with_frontmatter() {
  local JOB_ID
  JOB_ID="$(add_stub_job "Happy path" "model: test-model")"
  headrun run 2>/dev/null > /dev/null
  assert_equals "done" "$(job_state_of "${JOB_ID}")"
  local RESPONSE_TEXT
  RESPONSE_TEXT="$(headrun show "${JOB_ID}")"
  assert_contains "${RESPONSE_TEXT}" "status: done"
  assert_contains "${RESPONSE_TEXT}" "outcome: completed"
  assert_contains "${RESPONSE_TEXT}" "model: test-model"
  assert_contains "${RESPONSE_TEXT}" "# Stub response: Happy path"
  assert_contains "$(headrun show "${JOB_ID}" --prompt)" "Operating instructions"
  assert_contains "$(headrun show "${JOB_ID}" --prompt)" "Safety guidelines"
  assert_contains "$(headrun show "${JOB_ID}" --log)" "stub: finished"
  assert_exists "${HEADRUN_HOME}/headrun.log"
}

test_engine_failure_moves_on_to_next_job() {
  local FAILING_ID PASSING_ID
  FAILING_ID="$(add_stub_job "Breaks" "stub_exit: 3" "priority: 1")"
  PASSING_ID="$(add_stub_job "Works")"
  headrun run > /dev/null 2>&1
  assert_equals failed "$(job_state_of "${FAILING_ID}")"
  assert_equals "engine exited with status 3" "$(job_meta "${FAILING_ID}" reason)"
  assert_equals "done" "$(job_state_of "${PASSING_ID}")"
}

test_blocked_outcome_marks_job_failed() {
  local JOB_ID
  JOB_ID="$(add_stub_job "Blocked" "stub_outcome: blocked")"
  headrun run > /dev/null 2>&1
  assert_equals failed "$(job_state_of "${JOB_ID}")"
  assert_equals blocked "$(job_meta "${JOB_ID}" outcome)"
  assert_contains "$(headrun show "${JOB_ID}")" "reason: the agent reported the outcome as blocked"
}

test_missing_response_fails_with_runner_fallback() {
  local JOB_ID
  JOB_ID="$(add_stub_job "Silent" "stub_silent: yes")"
  headrun run > /dev/null 2>&1
  assert_equals failed "$(job_state_of "${JOB_ID}")"
  assert_contains "$(job_meta "${JOB_ID}" reason)" "produced no response"
  assert_equals runner "$(job_meta "${JOB_ID}" response_source)"
  assert_contains "$(headrun show "${JOB_ID}")" "# No response written"
}

test_timeout_fails_job() {
  local JOB_ID
  JOB_ID="$(add_stub_job "Slow" "timeout: 2s" "stub_sleep: 30")"
  local START_SECONDS="${SECONDS}"
  headrun run > /dev/null 2>&1
  if (( SECONDS - START_SECONDS > 10 )); then fail "timeout took too long"; fi
  assert_equals failed "$(job_state_of "${JOB_ID}")"
  assert_contains "$(job_meta "${JOB_ID}" reason)" "timed out after 2s"
}

test_no_engine_and_no_default_fails_at_run_time() {
  local JOB_ID
  JOB_ID="$(jobsheet "Engineless" | headrun add - 2>/dev/null)"
  headrun run > /dev/null 2>&1
  assert_equals failed "$(job_state_of "${JOB_ID}")"
  assert_contains "$(job_meta "${JOB_ID}" reason)" "no engine"
}

test_default_engine_is_used() {
  printf 'DEFAULT_ENGINE=stub\n' >> "${HEADRUN_CONFIG_DIR}/config"
  local JOB_ID
  JOB_ID="$(jobsheet "Defaulted" | headrun add - 2>/dev/null)"
  headrun run > /dev/null 2>&1
  assert_equals "done" "$(job_state_of "${JOB_ID}")"
  assert_equals stub "$(job_meta "${JOB_ID}" engine)"
}

test_missing_workdir_fails_unless_create_workdir() {
  local MISSING_ID CREATED_ID
  MISSING_ID="$(printf -- '---\nengine: stub\nworkdir: %s/absent\n---\nBody\n' "${TEST_SANDBOX_ROOT}" | headrun add - 2>/dev/null)"
  CREATED_ID="$(printf -- '---\nengine: stub\nworkdir: %s/created\ncreate_workdir: yes\n---\nBody\n' "${TEST_SANDBOX_ROOT}" | headrun add - 2>/dev/null)"
  headrun run > /dev/null 2>&1
  assert_equals failed "$(job_state_of "${MISSING_ID}")"
  assert_contains "$(job_meta "${MISSING_ID}" reason)" "workdir does not exist"
  assert_equals "done" "$(job_state_of "${CREATED_ID}")"
  assert_exists "${TEST_SANDBOX_ROOT}/created"
}

test_shell_engine_pipes_body_to_command() {
  local JOB_ID
  JOB_ID="$(printf -- '---\nengine: shell\nworkdir: %s\ncommand: tr a-z A-Z\n---\nshout this\n' "${TEST_WORKDIR}" | headrun add - 2>/dev/null)"
  headrun run > /dev/null 2>&1
  assert_equals "done" "$(job_state_of "${JOB_ID}")"
  assert_contains "$(headrun show "${JOB_ID}")" "SHOUT THIS"
}

test_paused_queue_is_not_run_and_once_runs_one() {
  local FIRST_ID SECOND_ID
  FIRST_ID="$(add_stub_job "One" "priority: 1")"
  SECOND_ID="$(add_stub_job "Two")"
  headrun pause 2>/dev/null
  headrun run > /dev/null 2>&1
  assert_equals pending "$(job_state_of "${FIRST_ID}")"
  headrun resume 2>/dev/null
  headrun run --once > /dev/null 2>&1
  assert_equals "done" "$(job_state_of "${FIRST_ID}")"
  assert_equals pending "$(job_state_of "${SECOND_ID}")"
}

runner_is_up() { [[ -s "${HEADRUN_HOME}/runner.pid" ]] && kill -0 "$(< "${HEADRUN_HOME}/runner.pid")" 2>/dev/null; }
runner_is_down() { ! runner_is_up; }
job_is_running() { [[ "$(job_state_of "$1")" == "running" ]]; }
job_is_in() { [[ "$(job_state_of "$1")" == "$2" ]]; }

test_detached_runner_lock_pause_and_stop_now() {
  local SLOW_ID NEXT_ID
  SLOW_ID="$(add_stub_job "Slow" "stub_sleep: 30" "priority: 1")"
  NEXT_ID="$(add_stub_job "Next")"
  headrun run --detach --watch 2>/dev/null
  wait_for 10 runner_is_up
  wait_for 10 job_is_running "${SLOW_ID}"

  local COMMAND_OUTPUT
  if COMMAND_OUTPUT="$(headrun run 2>&1)"; then fail "second runner should refuse to start"; fi
  assert_contains "${COMMAND_OUTPUT}" "a runner is already active"
  assert_contains "$(headrun status)" "current: ${SLOW_ID}"

  headrun pause 2>/dev/null
  headrun stop --now 2>/dev/null
  wait_for 15 runner_is_down
  assert_equals failed "$(job_state_of "${SLOW_ID}")"
  assert_contains "$(job_meta "${SLOW_ID}" reason)" "stopped by SIGTERM"
  assert_equals pending "$(job_state_of "${NEXT_ID}")"
}

test_watch_runner_picks_up_new_jobs_and_graceful_stop() {
  headrun run --detach --watch 2>/dev/null
  wait_for 10 runner_is_up
  local JOB_ID
  JOB_ID="$(add_stub_job "Late arrival")"
  wait_for 15 job_is_in "${JOB_ID}" "done"
  headrun stop 2>/dev/null
  wait_for 10 runner_is_down
}

test_orphaned_running_job_is_recovered() {
  local JOB_ID
  JOB_ID="$(add_stub_job "Orphan")"
  mv "${HEADRUN_HOME}/jobs/pending/${JOB_ID}" "${HEADRUN_HOME}/jobs/running/${JOB_ID}"
  printf 'started_at=1000\npid=999999\n' >> "${HEADRUN_HOME}/jobs/running/${JOB_ID}/meta"
  headrun run > /dev/null 2>&1
  assert_equals failed "$(job_state_of "${JOB_ID}")"
  assert_contains "$(job_meta "${JOB_ID}" reason)" "orphaned"
}

test_response_delivery_instruction_depends_on_permissions() {
  local BYPASS_ID READONLY_ID
  BYPASS_ID="$(add_stub_job "Bypass mode")"
  READONLY_ID="$(add_stub_job "Readonly mode" "permissions: readonly")"
  headrun run > /dev/null 2>&1
  assert_contains "$(headrun show "${BYPASS_ID}" --prompt)" "Response delivery: write the response to"
  assert_contains "$(headrun show "${READONLY_ID}" --prompt)" "Response delivery: make your final message the complete response"
}

test_gemini_adapter_against_a_fake_cli() {
  local FAKE_GEMINI="${TEST_SANDBOX_ROOT}/fake-gemini"
  cat > "${FAKE_GEMINI}" <<FAKE_SCRIPT
#!/usr/bin/env bash
case "\$1" in
  --version) echo 9.9.9; exit 0 ;;
  --help) echo "  --skip-trust  Trust the workspace"; exit 0 ;;
esac
printf '%s\n' "\$@" > "${TEST_SANDBOX_ROOT}/gemini-arguments"
cat > "${TEST_SANDBOX_ROOT}/gemini-stdin"
cat <<'EVENTS'
{"type":"init","timestamp":"t","session_id":"gem-session-1","model":"gemini-test"}
{"type":"message","timestamp":"t","role":"user","content":"ignored"}
{"type":"message","timestamp":"t","role":"assistant","content":"Let me look first.","delta":true}
{"type":"tool_use","timestamp":"t","tool_name":"run_shell_command","tool_id":"1","parameters":{"command":"ls"}}
{"type":"tool_result","timestamp":"t","tool_id":"1","status":"success","output":"x"}
{"type":"message","timestamp":"t","role":"assistant","content":"Outcome: completed\n\n","delta":true}
{"type":"message","timestamp":"t","role":"assistant","content":"All good.","delta":true}
{"type":"result","timestamp":"t","status":"success","stats":{"input_tokens":10,"output_tokens":5,"tool_calls":1,"duration_ms":1200}}
EVENTS
FAKE_SCRIPT
  chmod +x "${FAKE_GEMINI}"
  printf 'GEMINI_BIN=%s\n' "${FAKE_GEMINI}" >> "${HEADRUN_CONFIG_DIR}/config"

  local JOB_ID
  JOB_ID="$(jobsheet "Gemini" "engine: gemini" "model: flash" "dirs: /srv/reference" | headrun add - 2>/dev/null)"
  headrun run > /dev/null 2>&1
  assert_equals "done" "$(job_state_of "${JOB_ID}")"
  local RESPONSE_TEXT
  RESPONSE_TEXT="$(headrun show "${JOB_ID}")"
  assert_contains "${RESPONSE_TEXT}" "All good."
  assert_not_contains "${RESPONSE_TEXT}" "Let me look first."
  assert_equals "gem-session-1" "$(job_meta "${JOB_ID}" session_id)"
  assert_equals "gemini 9.9.9" "$(job_meta "${JOB_ID}" engine_version)"
  local ARGUMENT_TEXT
  ARGUMENT_TEXT="$(tr '\n' ' ' < "${TEST_SANDBOX_ROOT}/gemini-arguments")"
  assert_contains "${ARGUMENT_TEXT}" "--approval-mode yolo"
  assert_contains "${ARGUMENT_TEXT}" "--model flash"
  assert_contains "${ARGUMENT_TEXT}" "--include-directories /srv/reference"
  assert_contains "${ARGUMENT_TEXT}" "--skip-trust"
  assert_contains "$(< "${TEST_SANDBOX_ROOT}/gemini-stdin")" "Please do the thing."
}
