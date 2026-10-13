# shellcheck shell=bash
# Queue command tests: add, validation, ordering, lookup, edit-free mutations and prune.

test_add_reports_all_errors_and_queues_nothing() {
  local COMMAND_OUTPUT
  if COMMAND_OUTPUT="$(printf -- '---\nengine: nope\npriority: high\ntimeout: soon\nworkdir: relative/path\n---\n' | headrun add - 2>&1)"; then
    fail "invalid jobsheet should be rejected"
  fi
  assert_contains "${COMMAND_OUTPUT}" 'unknown engine "nope"'
  assert_contains "${COMMAND_OUTPUT}" "priority must be"
  assert_contains "${COMMAND_OUTPUT}" "timeout must be"
  assert_contains "${COMMAND_OUTPUT}" "workdir must be an absolute path"
  assert_contains "${COMMAND_OUTPUT}" "no body"
  assert_contains "${COMMAND_OUTPUT}" "5 problem(s)"
  assert_equals "" "$(headrun ls -q)"
  assert_equals "" "$(ls -A "${HEADRUN_HOME}/jobs/incoming")" "incoming should be empty"
}

test_add_warns_without_engine_but_queues() {
  local COMMAND_OUTPUT
  COMMAND_OUTPUT="$(jobsheet "No engine" | headrun add - 2>&1)"
  assert_contains "${COMMAND_OUTPUT}" "warn: stdin: no engine"
  assert_equals 1 "$(headrun ls -q | wc -l)"
}

test_add_check_validates_without_queueing() {
  jobsheet "Checked" "engine: stub" > "${TEST_SANDBOX_ROOT}/checked.md"
  headrun add --check "${TEST_SANDBOX_ROOT}/checked.md"
  assert_equals "" "$(headrun ls -q)"
}

test_add_overrides_create_frontmatter_and_title_from_heading() {
  local JOB_ID
  JOB_ID="$(printf '# Plain markdown title\n\nBody text\n' | headrun add -e stub -w "${TEST_WORKDIR}" -p 7 - 2>/dev/null)"
  assert_contains "${JOB_ID}" "-plain-markdown-title"
  assert_equals pending "$(job_state_of "${JOB_ID}")"
  assert_equals "Plain markdown title" "$(job_meta "${JOB_ID}" title)"
  local REQUEST_TEXT
  REQUEST_TEXT="$(headrun show "${JOB_ID}" --request)"
  assert_contains "${REQUEST_TEXT}" "engine: stub"
  assert_contains "${REQUEST_TEXT}" "priority: 7"
}

test_pending_order_is_priority_then_fifo() {
  local FIRST_ID SECOND_ID URGENT_ID
  FIRST_ID="$(add_stub_job "First")"
  sleep 1
  SECOND_ID="$(add_stub_job "Second")"
  URGENT_ID="$(add_stub_job "Urgent" "priority: 5")"
  assert_equals "${URGENT_ID} ${FIRST_ID} ${SECOND_ID}" "$(headrun ls -q --state pending | tr '\n' ' ' | sed 's/ $//')"
  headrun bump "${SECOND_ID}" 1 2>/dev/null
  assert_equals "${SECOND_ID}" "$(headrun ls -q --state pending | head -n 1)"
}

test_duplicate_titles_get_unique_ids() {
  local FIRST_ID SECOND_ID
  FIRST_ID="$(add_stub_job "Same")"
  SECOND_ID="$(add_stub_job "Same")"
  if [[ "${FIRST_ID}" == "${SECOND_ID}" ]]; then fail "ids should differ"; fi
}

test_job_lookup_by_prefix_substring_and_ambiguity() {
  local ALPHA_ID
  ALPHA_ID="$(add_stub_job "Alpha job")"
  add_stub_job "Beta job" > /dev/null
  assert_equals "${ALPHA_ID}" "$(basename "$(headrun show alpha --path)")"
  assert_equals "${ALPHA_ID}" "$(basename "$(headrun show "${ALPHA_ID%-job}" --path)")"
  local COMMAND_OUTPUT
  if COMMAND_OUTPUT="$(headrun show job --path 2>&1)"; then fail "ambiguous query should fail"; fi
  assert_contains "${COMMAND_OUTPUT}" "matches more than one job"
  if COMMAND_OUTPUT="$(headrun show zzz --path 2>&1)"; then fail "missing job should fail"; fi
  assert_contains "${COMMAND_OUTPUT}" 'no job matches "zzz"'
}

test_cancel_and_requeue() {
  local JOB_ID NEW_ID
  JOB_ID="$(add_stub_job "Cancel me")"
  headrun cancel "${JOB_ID}" 2>/dev/null
  assert_equals cancelled "$(job_state_of "${JOB_ID}")"
  assert_equals "cancelled by operator" "$(job_meta "${JOB_ID}" reason)"
  NEW_ID="$(headrun requeue "${JOB_ID}" --priority 3 2>/dev/null)"
  assert_equals pending "$(job_state_of "${NEW_ID}")"
  assert_equals "${JOB_ID}" "$(job_meta "${NEW_ID}" requeued_from)"
  assert_contains "$(headrun show "${NEW_ID}" --request)" "priority: 3"
  local COMMAND_OUTPUT
  if COMMAND_OUTPUT="$(headrun requeue "${NEW_ID}" 2>&1)"; then fail "pending job should not requeue"; fi
  assert_contains "${COMMAND_OUTPUT}" "only finished jobs"
}

test_prune_archives_then_deletes_old_jobs() {
  local OLD_ID RECENT_ID
  OLD_ID="$(add_stub_job "Old")"
  RECENT_ID="$(add_stub_job "Recent")"
  headrun cancel "${OLD_ID}" "${RECENT_ID}" 2>/dev/null
  local OLD_META="${HEADRUN_HOME}/jobs/cancelled/${OLD_ID}/meta"
  sed -i 's/^finished_at=.*/finished_at=1000/' "${OLD_META}"
  headrun prune --older-than 1d > /dev/null 2>&1
  assert_equals archive "$(job_state_of "${OLD_ID}")"
  assert_equals cancelled "$(job_state_of "${RECENT_ID}")"
  assert_not_contains "$(headrun ls -q)" "${OLD_ID}"
  assert_contains "$(headrun ls -q --all)" "${OLD_ID}"
  headrun prune --older-than 1d --delete > /dev/null 2>&1
  assert_equals "" "$(job_state_of "${OLD_ID}")"
}

test_same_second_jobs_run_fifo() {
  local ZULU_ID ALPHA_ID
  ZULU_ID="$(add_stub_job "Zulu")"
  ALPHA_ID="$(add_stub_job "Alpha")"
  assert_equals "${ZULU_ID} ${ALPHA_ID}" "$(headrun ls -q --state pending | tr '\n' ' ' | sed 's/ $//')"
}
