# shellcheck shell=bash
# Test helpers: sandbox setup, assertions, and jobsheet builders.

# Creates an isolated config/data/workdir under the sandbox and exports the headrun environment.
sandbox_setup() {
  local SANDBOX_ROOT="$1"
  export TEST_SANDBOX_ROOT="${SANDBOX_ROOT}"
  export HEADRUN_HOME="${SANDBOX_ROOT}/data"
  export HEADRUN_CONFIG_DIR="${SANDBOX_ROOT}/config"
  export TEST_WORKDIR="${SANDBOX_ROOT}/work"
  mkdir -p "${HEADRUN_CONFIG_DIR}" "${TEST_WORKDIR}"
  printf 'POLL_INTERVAL=1s\nKILL_GRACE=1s\n' > "${HEADRUN_CONFIG_DIR}/config"
  set -o errexit -o nounset -o pipefail
}

# Stops any runner left in the sandbox.
sandbox_teardown() {
  local SANDBOX_ROOT="$1"
  local RUNNER_PID_PATH="${SANDBOX_ROOT}/data/runner.pid"
  if [[ -s "${RUNNER_PID_PATH}" ]]; then
    local LEFTOVER_RUNNER_ID
    LEFTOVER_RUNNER_ID="$(< "${RUNNER_PID_PATH}")"
    if kill -0 "${LEFTOVER_RUNNER_ID}" 2>/dev/null; then
      kill -KILL "${LEFTOVER_RUNNER_ID}"
    fi
  fi
}

# Runs the headrun under test.
headrun() {
  "${REPOSITORY_ROOT}/bin/headrun" "$@"
}

# Fails the current test with a message.
fail() {
  printf 'assertion failed: %s\n' "$*" >&2
  exit 1
}

# Asserts two strings are equal.
assert_equals() {
  local EXPECTED_VALUE="$1"
  local ACTUAL_VALUE="$2"
  local ASSERT_LABEL="${3:-value}"
  if [[ "${EXPECTED_VALUE}" != "${ACTUAL_VALUE}" ]]; then
    fail "${ASSERT_LABEL}: expected [${EXPECTED_VALUE}] got [${ACTUAL_VALUE}]"
  fi
}

# Asserts a string contains a substring.
assert_contains() {
  local HAYSTACK_TEXT="$1"
  local NEEDLE_TEXT="$2"
  if [[ "${HAYSTACK_TEXT}" != *"${NEEDLE_TEXT}"* ]]; then
    fail "expected to find [${NEEDLE_TEXT}] in: ${HAYSTACK_TEXT}"
  fi
}

# Asserts a string does not contain a substring.
assert_not_contains() {
  local HAYSTACK_TEXT="$1"
  local NEEDLE_TEXT="$2"
  if [[ "${HAYSTACK_TEXT}" == *"${NEEDLE_TEXT}"* ]]; then
    fail "did not expect [${NEEDLE_TEXT}] in: ${HAYSTACK_TEXT}"
  fi
}

# Asserts a path exists.
assert_exists() {
  local EXPECTED_PATH="$1"
  if [[ ! -e "${EXPECTED_PATH}" ]]; then
    fail "expected path to exist: ${EXPECTED_PATH}"
  fi
}

# Prints the state directory currently holding a job id.
job_state_of() {
  local JOB_ID="$1"
  local STATE_PATH
  STATE_PATH="$(find "${HEADRUN_HOME}/jobs" -mindepth 2 -maxdepth 2 -name "${JOB_ID}" -printf '%h\n')"
  printf '%s' "${STATE_PATH##*/}"
}

# Prints a value from a job's meta file.
job_meta() {
  local JOB_ID="$1"
  local META_KEY="$2"
  local JOB_PATH
  JOB_PATH="$(find "${HEADRUN_HOME}/jobs" -mindepth 2 -maxdepth 2 -name "${JOB_ID}")"
  awk -v meta_key="${META_KEY}" 'index($0, meta_key "=") == 1 { value = substr($0, length(meta_key) + 2) } END { printf "%s", value }' "${JOB_PATH}/meta"
}

# Writes a jobsheet with the given extra frontmatter lines to stdout.
jobsheet() {
  local JOB_TITLE="$1"
  shift
  printf -- '---\ntitle: %s\nworkdir: %s\n' "${JOB_TITLE}" "${TEST_WORKDIR}"
  local EXTRA_LINE
  for EXTRA_LINE in "$@"; do
    printf '%s\n' "${EXTRA_LINE}"
  done
  printf -- '---\n\n# %s\n\nPlease do the thing.\n' "${JOB_TITLE}"
}

# Queues a stub jobsheet and prints its id.
add_stub_job() {
  local JOB_TITLE="$1"
  shift
  jobsheet "${JOB_TITLE}" "engine: stub" "$@" | headrun add - 2>/dev/null
}

# Waits (up to the given seconds) until a command succeeds.
wait_for() {
  local WAIT_SECONDS="$1"
  shift
  local WAIT_DEADLINE=$(( SECONDS + WAIT_SECONDS ))
  until "$@"; do
    if (( SECONDS >= WAIT_DEADLINE )); then
      fail "timed out after ${WAIT_SECONDS}s waiting for: $*"
    fi
    sleep 0.2
  done
}

# Sources the headrun libraries into the test shell and loads config, for unit tests.
load_library() {
  local LIBRARY_FILE
  for LIBRARY_FILE in log util config frontmatter queue runner commands; do
    # shellcheck source=/dev/null
    source "${REPOSITORY_ROOT}/lib/${LIBRARY_FILE}.sh"
  done
  HEADRUN_ENTRY_SCRIPT="${REPOSITORY_ROOT}/bin/headrun"
  config_read_environment "${HEADRUN_ENTRY_SCRIPT}"
  config_load
}
