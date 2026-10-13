#!/usr/bin/env bash
# headrun engine adapter: Google Gemini CLI (gemini -p), streaming JSON rendered through jq when available.

set -o errexit -o nounset -o pipefail

ADAPTER_ACTION="${1:-run}"
GEMINI_COMMAND="${HEADRUN_ENGINE_BIN:-gemini}"

case "${ADAPTER_ACTION}" in
  check)
    if ! command -v "${GEMINI_COMMAND}" > /dev/null; then
      printf '%s not found (set GEMINI_BIN in the config)\n' "${GEMINI_COMMAND}"
      exit 1
    fi
    printf 'gemini %s\n' "$("${GEMINI_COMMAND}" --version 2>&1 | sed -n 1p)"
    exit 0
    ;;
  run) ;;
  *)
    printf 'gemini: unknown action %s\n' "${ADAPTER_ACTION}" >&2
    exit 2
    ;;
esac

printf 'engine_version=gemini %s\n' "$("${GEMINI_COMMAND}" --version 2>&1 | sed -n 1p)" >> "${HEADRUN_ENGINE_META}"

# -p text is appended to stdin, so the composed prompt goes on stdin and -p only adds a closing line.
GEMINI_ARGUMENTS=(--output-format stream-json)
if [[ -n "${HEADRUN_MODEL}" ]]; then
  GEMINI_ARGUMENTS+=(--model "${HEADRUN_MODEL}")
fi
case "${HEADRUN_PERMISSIONS}" in
  bypass) GEMINI_ARGUMENTS+=(--approval-mode yolo) ;;
  auto|edits) GEMINI_ARGUMENTS+=(--approval-mode auto_edit) ;;
  readonly) GEMINI_ARGUMENTS+=(--approval-mode plan) ;;
  *)
    printf 'gemini: unsupported permissions mode %s\n' "${HEADRUN_PERMISSIONS}" >&2
    exit 2
    ;;
esac
if [[ -n "${HEADRUN_DIRS}" ]]; then
  IFS=',' read -ra EXTRA_DIRECTORIES <<< "${HEADRUN_DIRS}"
  for EXTRA_DIRECTORY in "${EXTRA_DIRECTORIES[@]}"; do
    EXTRA_DIRECTORY="${EXTRA_DIRECTORY#"${EXTRA_DIRECTORY%%[![:space:]]*}"}"
    EXTRA_DIRECTORY="${EXTRA_DIRECTORY%"${EXTRA_DIRECTORY##*[![:space:]]}"}"
    GEMINI_ARGUMENTS+=(--include-directories "${EXTRA_DIRECTORY}")
  done
fi
# Gemini confines file writes to its workspace even in yolo mode, so the job directory is added for response.md.
GEMINI_ARGUMENTS+=(--include-directories "${HEADRUN_JOB_DIR}")
# Nobody can answer the folder-trust prompt unattended; older releases lack the flag.
if "${GEMINI_COMMAND}" --help 2>&1 | grep -q -e '--skip-trust'; then
  GEMINI_ARGUMENTS+=(--skip-trust)
fi
GEMINI_ARGUMENTS+=(--prompt "Carry out the job described above.")

STREAM_FILE="${HEADRUN_JOB_DIR}/gemini-stream.jsonl"
RENDERER_FILE="${HEADRUN_APP_ROOT}/engines/gemini-render.jq"

printf 'gemini: %s %s < prompt.md\n' "${GEMINI_COMMAND}" "${GEMINI_ARGUMENTS[*]}"

set +o errexit
if command -v jq > /dev/null; then
  "${GEMINI_COMMAND}" "${GEMINI_ARGUMENTS[@]}" < "${HEADRUN_PROMPT}" \
    | tee "${STREAM_FILE}" \
    | jq --unbuffered -R -r -j -f "${RENDERER_FILE}"
  PIPELINE_STATUSES=("${PIPESTATUS[@]}")
else
  "${GEMINI_COMMAND}" "${GEMINI_ARGUMENTS[@]}" < "${HEADRUN_PROMPT}" | tee "${STREAM_FILE}"
  PIPELINE_STATUSES=("${PIPESTATUS[@]}")
fi
set -o errexit
GEMINI_STATUS="${PIPELINE_STATUSES[0]}"

if command -v jq > /dev/null && [[ -s "${STREAM_FILE}" ]]; then
  jq -R -s -r '
    [split("\n")[] | try fromjson catch empty] as $events
    | ($events | map(select(.type == "init")) | first) as $init_event
    | ($events | map(select(.type == "result")) | last) as $result_event
    | (if $init_event.session_id then "session_id=\($init_event.session_id)" else empty end),
      (if $result_event.stats then
         "engine_note=tokens in \($result_event.stats.input_tokens // "?") out \($result_event.stats.output_tokens // "?"), tool calls \($result_event.stats.tool_calls // "?")"
       else empty end)
  ' "${STREAM_FILE}" >> "${HEADRUN_ENGINE_META}"

  # The final message is the assistant text after the last tool call; delta events are chunks to join.
  FINAL_MESSAGE_FILE="${HEADRUN_JOB_DIR}/gemini-final-message.md"
  jq -R -s -r '
    reduce ([split("\n")[] | try fromjson catch empty][]) as $event ("";
      if $event.type == "tool_use" then ""
      elif $event.type == "message" and $event.role == "assistant" then
        if $event.delta == true then . + ($event.content // "") else ($event.content // "") end
      else . end)
  ' "${STREAM_FILE}" > "${FINAL_MESSAGE_FILE}"

  if [[ ! -s "${HEADRUN_RESPONSE}" ]]; then
    if [[ -n "$(tr -d '[:space:]' < "${FINAL_MESSAGE_FILE}")" ]]; then
      cp "${FINAL_MESSAGE_FILE}" "${HEADRUN_RESPONSE}"
      printf 'gemini: no response file written; used the final message instead\n'
    else
      printf 'gemini: no response file written and no final message to use\n'
    fi
  fi
fi

exit "${GEMINI_STATUS}"
