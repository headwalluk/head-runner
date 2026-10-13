#!/usr/bin/env bash
# headrun engine adapter: Claude Code (claude --print), streaming JSON rendered through jq when available.

set -o errexit -o nounset -o pipefail

ADAPTER_ACTION="${1:-run}"
CLAUDE_COMMAND="${HEADRUN_ENGINE_BIN:-claude}"

case "${ADAPTER_ACTION}" in
  check)
    if ! command -v "${CLAUDE_COMMAND}" > /dev/null; then
      printf '%s not found (set CLAUDE_BIN in the config)\n' "${CLAUDE_COMMAND}"
      exit 1
    fi
    printf '%s\n' "$("${CLAUDE_COMMAND}" --version 2>&1 | head -n 1)"
    exit 0
    ;;
  run) ;;
  *)
    printf 'claude: unknown action %s\n' "${ADAPTER_ACTION}" >&2
    exit 2
    ;;
esac

CLAUDE_ARGUMENTS=(--print --output-format stream-json --verbose)
if [[ -n "${HEADRUN_MODEL}" ]]; then
  CLAUDE_ARGUMENTS+=(--model "${HEADRUN_MODEL}")
fi
case "${HEADRUN_PERMISSIONS}" in
  bypass) CLAUDE_ARGUMENTS+=(--dangerously-skip-permissions) ;;
  auto) CLAUDE_ARGUMENTS+=(--permission-mode auto) ;;
  edits) CLAUDE_ARGUMENTS+=(--permission-mode acceptEdits) ;;
  readonly) CLAUDE_ARGUMENTS+=(--permission-mode plan) ;;
  *)
    printf 'claude: unsupported permissions mode %s\n' "${HEADRUN_PERMISSIONS}" >&2
    exit 2
    ;;
esac
if [[ -n "${HEADRUN_DIRS}" ]]; then
  IFS=',' read -ra EXTRA_DIRECTORIES <<< "${HEADRUN_DIRS}"
  for EXTRA_DIRECTORY in "${EXTRA_DIRECTORIES[@]}"; do
    EXTRA_DIRECTORY="${EXTRA_DIRECTORY#"${EXTRA_DIRECTORY%%[![:space:]]*}"}"
    EXTRA_DIRECTORY="${EXTRA_DIRECTORY%"${EXTRA_DIRECTORY##*[![:space:]]}"}"
    CLAUDE_ARGUMENTS+=(--add-dir "${EXTRA_DIRECTORY}")
  done
fi

STREAM_FILE="${HEADRUN_JOB_DIR}/claude-stream.jsonl"
RENDERER_FILE="${HEADRUN_APP_ROOT}/engines/claude-render.jq"

printf 'claude: %s %s < prompt.md\n' "${CLAUDE_COMMAND}" "${CLAUDE_ARGUMENTS[*]}"

set +o errexit
if command -v jq > /dev/null; then
  "${CLAUDE_COMMAND}" "${CLAUDE_ARGUMENTS[@]}" < "${HEADRUN_PROMPT}" \
    | tee "${STREAM_FILE}" \
    | jq --unbuffered -R -r -j -f "${RENDERER_FILE}"
  PIPELINE_STATUSES=("${PIPESTATUS[@]}")
else
  "${CLAUDE_COMMAND}" "${CLAUDE_ARGUMENTS[@]}" < "${HEADRUN_PROMPT}" | tee "${STREAM_FILE}"
  PIPELINE_STATUSES=("${PIPESTATUS[@]}")
fi
set -o errexit
CLAUDE_STATUS="${PIPELINE_STATUSES[0]}"

if command -v jq > /dev/null && [[ -s "${STREAM_FILE}" ]]; then
  RESULT_EVENT="$(jq -R -c 'try fromjson catch empty | select(.type == "result")' "${STREAM_FILE}" | tail -n 1)"
  if [[ -n "${RESULT_EVENT}" ]]; then
    jq -r '"session_id=\(.session_id // "")", "cost_usd=\(.total_cost_usd // "")", "num_turns=\(.num_turns // "")"' \
      <<< "${RESULT_EVENT}" >> "${HEADRUN_ENGINE_META}"
    if [[ ! -s "${HEADRUN_RESPONSE}" ]]; then
      jq -r '.result // empty' <<< "${RESULT_EVENT}" > "${HEADRUN_RESPONSE}"
      printf 'claude: no response file written; used the final result message instead\n'
    fi
  fi
fi

exit "${CLAUDE_STATUS}"
