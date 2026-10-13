#!/usr/bin/env bash
# headrun engine adapter: shell — runs the jobsheet's "command:" with the request body on stdin; stdout becomes the response.
# headrun-keys: command

set -o errexit -o nounset -o pipefail

ADAPTER_ACTION="${1:-run}"

case "${ADAPTER_ACTION}" in
  check)
    printf 'built-in (runs the jobsheet "command:" with bash)\n'
    exit 0
    ;;
  run) ;;
  *)
    printf 'shell: unknown action %s\n' "${ADAPTER_ACTION}" >&2
    exit 2
    ;;
esac

SHELL_COMMAND="${HEADRUN_FM_COMMAND:-}"
if [[ -z "${SHELL_COMMAND}" ]]; then
  printf 'shell: the jobsheet needs a "command:" frontmatter key\n' >&2
  exit 2
fi

REQUEST_BODY_FILE="${HEADRUN_JOB_DIR}/request-body.md"
awk '
  NR == 1 && /^---[ \t\r]*$/ { in_block = 1; next }
  in_block && /^(---|\.\.\.)[ \t\r]*$/ { in_block = 0; next }
  in_block { next }
  !started && /^[ \t\r]*$/ { next }
  { started = 1; print }
' "${HEADRUN_REQUEST}" > "${REQUEST_BODY_FILE}"

COMMAND_OUTPUT_FILE="${HEADRUN_JOB_DIR}/command-output.md"
printf 'shell: running: %s\n' "${SHELL_COMMAND}" >&2
COMMAND_STATUS=0
bash -c "${SHELL_COMMAND}" < "${REQUEST_BODY_FILE}" > "${COMMAND_OUTPUT_FILE}" || COMMAND_STATUS=$?
printf 'shell: command exited with status %s\n' "${COMMAND_STATUS}" >&2

if [[ ! -s "${HEADRUN_RESPONSE}" && -s "${COMMAND_OUTPUT_FILE}" ]]; then
  mv "${COMMAND_OUTPUT_FILE}" "${HEADRUN_RESPONSE}"
fi
exit "${COMMAND_STATUS}"
