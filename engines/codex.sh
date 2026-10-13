#!/usr/bin/env bash
# headrun engine adapter: OpenAI Codex CLI (codex exec). Untested against a live install; see docs/engines.md.

set -o errexit -o nounset -o pipefail

ADAPTER_ACTION="${1:-run}"
CODEX_COMMAND="${HEADRUN_ENGINE_BIN:-codex}"

case "${ADAPTER_ACTION}" in
  check)
    if ! command -v "${CODEX_COMMAND}" > /dev/null; then
      printf '%s not found (set CODEX_BIN in the config)\n' "${CODEX_COMMAND}"
      exit 1
    fi
    printf '%s (adapter untested)\n' "$("${CODEX_COMMAND}" --version 2>&1 | head -n 1)"
    exit 0
    ;;
  run) ;;
  *)
    printf 'codex: unknown action %s\n' "${ADAPTER_ACTION}" >&2
    exit 2
    ;;
esac

LAST_MESSAGE_FILE="${HEADRUN_JOB_DIR}/codex-last-message.md"
CODEX_ARGUMENTS=(exec --cd "${HEADRUN_WORKDIR}" --skip-git-repo-check --output-last-message "${LAST_MESSAGE_FILE}")
if [[ -n "${HEADRUN_MODEL}" ]]; then
  CODEX_ARGUMENTS+=(--model "${HEADRUN_MODEL}")
fi
case "${HEADRUN_PERMISSIONS}" in
  bypass) CODEX_ARGUMENTS+=(--dangerously-bypass-approvals-and-sandbox) ;;
  auto|edits) CODEX_ARGUMENTS+=(--full-auto) ;;
  readonly) CODEX_ARGUMENTS+=(--sandbox read-only) ;;
  *)
    printf 'codex: unsupported permissions mode %s\n' "${HEADRUN_PERMISSIONS}" >&2
    exit 2
    ;;
esac
if [[ -n "${HEADRUN_DIRS}" ]]; then
  IFS=',' read -ra EXTRA_DIRECTORIES <<< "${HEADRUN_DIRS}"
  for EXTRA_DIRECTORY in "${EXTRA_DIRECTORIES[@]}"; do
    EXTRA_DIRECTORY="${EXTRA_DIRECTORY#"${EXTRA_DIRECTORY%%[![:space:]]*}"}"
    EXTRA_DIRECTORY="${EXTRA_DIRECTORY%"${EXTRA_DIRECTORY##*[![:space:]]}"}"
    CODEX_ARGUMENTS+=(--add-dir "${EXTRA_DIRECTORY}")
  done
fi

printf 'codex: %s %s - < prompt.md\n' "${CODEX_COMMAND}" "${CODEX_ARGUMENTS[*]}"
CODEX_STATUS=0
"${CODEX_COMMAND}" "${CODEX_ARGUMENTS[@]}" - < "${HEADRUN_PROMPT}" || CODEX_STATUS=$?

if [[ ! -s "${HEADRUN_RESPONSE}" && -s "${LAST_MESSAGE_FILE}" ]]; then
  cp "${LAST_MESSAGE_FILE}" "${HEADRUN_RESPONSE}"
  printf 'codex: no response file written; used the last message instead\n'
fi

exit "${CODEX_STATUS}"
