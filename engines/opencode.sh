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
    printf 'opencode: permissions "%s" uses your opencode.json permission settings; anything that would prompt is auto-rejected\n' "${HEADRUN_PERMISSIONS}"
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

# "opencode run" can exit before flushing its last JSON events, so the session export is the reliable record.
if command -v jq > /dev/null && [[ -s "${STREAM_FILE}" ]]; then
  SESSION_ID="$(jq -R -r 'try fromjson catch empty | .sessionID // empty' "${STREAM_FILE}" | head -n 1)"
  EXPORT_FILE="${HEADRUN_JOB_DIR}/opencode-session.json"
  if [[ -n "${SESSION_ID}" ]]; then
    printf 'session_id=%s\n' "${SESSION_ID}" >> "${HEADRUN_ENGINE_META}"
    if ! "${OPENCODE_COMMAND}" export "${SESSION_ID}" > "${EXPORT_FILE}" 2>> "${HEADRUN_JOB_DIR}/transcript.log"; then
      printf 'opencode: could not export session %s; falling back to the event stream\n' "${SESSION_ID}"
      rm -f "${EXPORT_FILE}"
    fi
  fi

  FINAL_MESSAGE_FILE="${HEADRUN_JOB_DIR}/opencode-final-message.md"
  if [[ -s "${EXPORT_FILE:-}" ]] && jq -e '.messages' "${EXPORT_FILE}" > /dev/null 2>&1; then
    jq -r '"cost_usd=\([.messages[].info.cost // 0] | add | . * 1000000 | round / 1000000)"' "${EXPORT_FILE}" >> "${HEADRUN_ENGINE_META}"
    jq -r '
      [.messages[] | select(.info.role == "assistant")] | last
      | if . == null then empty else [.parts[]? | select(.type == "text") | .text] | join("\n\n") end
    ' "${EXPORT_FILE}" > "${FINAL_MESSAGE_FILE}"
  else
    jq -R -s -r '
      [split("\n")[] | try fromjson catch empty] as $events
      | "cost_usd=\($events | map(select(.type == "step_finish") | .part.cost // 0) | add // 0 | . * 1000000 | round / 1000000)"
    ' "${STREAM_FILE}" >> "${HEADRUN_ENGINE_META}"
    jq -R -s -r '
      [split("\n")[] | try fromjson catch empty | select(.type == "text")] as $text_events
      | if ($text_events | length) == 0 then empty else
          ($text_events | last | .part.messageID) as $final_message
          | $text_events | map(select(.part.messageID == $final_message) | .part.text) | join("\n\n")
        end
    ' "${STREAM_FILE}" > "${FINAL_MESSAGE_FILE}"
  fi

  if [[ ! -s "${HEADRUN_RESPONSE}" ]]; then
    if [[ -n "$(tr -d '[:space:]' < "${FINAL_MESSAGE_FILE}")" ]]; then
      cp "${FINAL_MESSAGE_FILE}" "${HEADRUN_RESPONSE}"
      printf 'opencode: no response file written; used the final message instead\n'
    else
      printf 'opencode: no response file written and no final message to use\n'
    fi
  fi
fi

exit "${OPENCODE_STATUS}"
