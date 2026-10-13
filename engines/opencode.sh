#!/usr/bin/env bash
# headrun engine adapter: OpenCode (opencode run), JSON events rendered through jq when available.

set -o errexit -o nounset -o pipefail

ADAPTER_ACTION="${1:-run}"
OPENCODE_COMMAND="${HEADRUN_ENGINE_BIN:-opencode}"

case "${ADAPTER_ACTION}" in
  check)
    if ! command -v "${OPENCODE_COMMAND}" > /dev/null; then
      printf '%s not found (set OPENCODE_BIN in the config)\n' "${OPENCODE_COMMAND}"
      exit 1
    fi
    printf 'opencode %s\n' "$("${OPENCODE_COMMAND}" --version 2>&1 | head -n 1)"
    exit 0
    ;;
  run) ;;
  *)
    printf 'opencode: unknown action %s\n' "${ADAPTER_ACTION}" >&2
    exit 2
    ;;
esac

OPENCODE_ARGUMENTS=(run --dir "${HEADRUN_WORKDIR}" --title "headrun ${HEADRUN_JOB_ID}")
if [[ -n "${HEADRUN_MODEL}" ]]; then
  OPENCODE_ARGUMENTS+=(--model "${HEADRUN_MODEL}")
fi
case "${HEADRUN_PERMISSIONS}" in
  bypass) OPENCODE_ARGUMENTS+=(--dangerously-skip-permissions) ;;
  auto|edits|readonly)
    printf 'opencode: permissions "%s" defers to your opencode.json permission settings; unanswered prompts may stall the job\n' "${HEADRUN_PERMISSIONS}"
    ;;
  *)
    printf 'opencode: unsupported permissions mode %s\n' "${HEADRUN_PERMISSIONS}" >&2
    exit 2
    ;;
esac

STREAM_FILE="${HEADRUN_JOB_DIR}/opencode-stream.jsonl"
RENDERER_FILE="${HEADRUN_APP_ROOT}/engines/opencode-render.jq"

set +o errexit
if command -v jq > /dev/null; then
  OPENCODE_ARGUMENTS+=(--format json)
  printf 'opencode: %s %s < prompt.md\n' "${OPENCODE_COMMAND}" "${OPENCODE_ARGUMENTS[*]}"
  "${OPENCODE_COMMAND}" "${OPENCODE_ARGUMENTS[@]}" < "${HEADRUN_PROMPT}" \
    | tee "${STREAM_FILE}" \
    | jq --unbuffered -R -r -j -f "${RENDERER_FILE}"
  PIPELINE_STATUSES=("${PIPESTATUS[@]}")
else
  printf 'opencode: %s %s < prompt.md\n' "${OPENCODE_COMMAND}" "${OPENCODE_ARGUMENTS[*]}"
  "${OPENCODE_COMMAND}" "${OPENCODE_ARGUMENTS[@]}" < "${HEADRUN_PROMPT}"
  PIPELINE_STATUSES=("${PIPESTATUS[@]}")
fi
set -o errexit
OPENCODE_STATUS="${PIPELINE_STATUSES[0]}"

if command -v jq > /dev/null && [[ -s "${STREAM_FILE}" ]]; then
  jq -R -s -r '
    [split("\n")[] | try fromjson catch empty] as $events
    | "session_id=\(($events | map(.sessionID // empty) | first) // "")",
      "cost_usd=\($events | map(select(.type == "step_finish") | .part.cost // 0) | add // "")"
  ' "${STREAM_FILE}" >> "${HEADRUN_ENGINE_META}"
  if [[ ! -s "${HEADRUN_RESPONSE}" ]]; then
    jq -R -s -r '[split("\n")[] | try fromjson catch empty | select(.type == "text") | .part.text] | last // empty' \
      "${STREAM_FILE}" > "${HEADRUN_RESPONSE}"
    printf 'opencode: no response file written; used the final text message instead\n'
  fi
fi

exit "${OPENCODE_STATUS}"
