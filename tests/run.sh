#!/usr/bin/env bash
# Minimal test runner: sources tests/*.test.sh and runs each test_* function in an isolated sandbox.

set -o errexit -o nounset -o pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
TEST_FILTER="${1:-}"
PASSED_COUNT=0
FAILED_COUNT=0
FAILED_NAMES=()

export NO_COLOR=1
export REPOSITORY_ROOT

# shellcheck source=helpers.sh
source "${TESTS_DIR}/helpers.sh"

for TEST_FILE in "${TESTS_DIR}"/*.test.sh; do
  TEST_FUNCTIONS="$(bash -c "source '${TESTS_DIR}/helpers.sh'; source '${TEST_FILE}'; declare -F" | awk '$3 ~ /^test_/ { print $3 }')"
  for TEST_FUNCTION in ${TEST_FUNCTIONS}; do
    if [[ -n "${TEST_FILTER}" && "${TEST_FUNCTION}" != *"${TEST_FILTER}"* ]]; then
      continue
    fi
    TEST_SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/headrun-test.XXXXXX")"
    TEST_OUTPUT_FILE="${TEST_SANDBOX}/test-output.log"
    TEST_STATUS=0
    (
      sandbox_setup "${TEST_SANDBOX}"
      # shellcheck source=/dev/null
      source "${TEST_FILE}"
      "${TEST_FUNCTION}"
    ) > "${TEST_OUTPUT_FILE}" 2>&1 || TEST_STATUS=$?
    sandbox_teardown "${TEST_SANDBOX}"
    if (( TEST_STATUS == 0 )); then
      PASSED_COUNT=$(( PASSED_COUNT + 1 ))
      printf 'ok    %s\n' "${TEST_FUNCTION}"
    else
      FAILED_COUNT=$(( FAILED_COUNT + 1 ))
      FAILED_NAMES+=("${TEST_FUNCTION}")
      printf 'FAIL  %s\n' "${TEST_FUNCTION}"
      sed 's/^/      | /' "${TEST_OUTPUT_FILE}"
    fi
    rm -rf "${TEST_SANDBOX}"
  done
done

printf '\n%d passed, %d failed\n' "${PASSED_COUNT}" "${FAILED_COUNT}"
if (( FAILED_COUNT > 0 )); then
  printf 'failed: %s\n' "${FAILED_NAMES[*]}"
  exit 1
fi
