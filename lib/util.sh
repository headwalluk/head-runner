# shellcheck shell=bash
# General helpers: durations, timestamps, slugs, colour.

COLOUR_RESET=""
COLOUR_DIM=""
COLOUR_BOLD=""
COLOUR_RED=""
COLOUR_GREEN=""
COLOUR_YELLOW=""
COLOUR_BLUE=""

# Enables ANSI colour variables when stdout is a terminal and colour is allowed.
colour_init() {
  local COLOUR_ALLOWED="$1"
  if [[ "${COLOUR_ALLOWED}" == "1" && -t 1 ]]; then
    COLOUR_RESET=$'\e[0m'
    COLOUR_DIM=$'\e[2m'
    COLOUR_BOLD=$'\e[1m'
    COLOUR_RED=$'\e[31m'
    COLOUR_GREEN=$'\e[32m'
    COLOUR_YELLOW=$'\e[33m'
    COLOUR_BLUE=$'\e[34m'
  fi
}

# Converts a duration such as 90, 45s, 30m, 2h, 1h30m or 1d into seconds; returns 1 if malformed.
duration_to_seconds() {
  local DURATION_TEXT="$1"
  local TOTAL_SECONDS=0
  local IS_VALID=1

  if [[ "${DURATION_TEXT}" =~ ^[0-9]+$ ]]; then
    TOTAL_SECONDS=$(( 10#${DURATION_TEXT} ))
  elif [[ "${DURATION_TEXT}" =~ ^([0-9]+d)?([0-9]+h)?([0-9]+m)?([0-9]+s)?$ && -n "${DURATION_TEXT}" ]]; then
    local DURATION_PART
    for DURATION_PART in "${BASH_REMATCH[@]:1}"; do
      if [[ -z "${DURATION_PART}" ]]; then
        continue
      fi
      local PART_NUMBER="${DURATION_PART%?}"
      local PART_UNIT="${DURATION_PART: -1}"
      case "${PART_UNIT}" in
        d) TOTAL_SECONDS=$(( TOTAL_SECONDS + 10#${PART_NUMBER} * 86400 )) ;;
        h) TOTAL_SECONDS=$(( TOTAL_SECONDS + 10#${PART_NUMBER} * 3600 )) ;;
        m) TOTAL_SECONDS=$(( TOTAL_SECONDS + 10#${PART_NUMBER} * 60 )) ;;
        s) TOTAL_SECONDS=$(( TOTAL_SECONDS + 10#${PART_NUMBER} )) ;;
        *) IS_VALID=0 ;;
      esac
    done
  else
    IS_VALID=0
  fi

  if (( IS_VALID == 0 )); then
    return 1
  fi
  printf '%s' "${TOTAL_SECONDS}"
}

# Formats a number of seconds as a compact human duration, e.g. 1h05m or 42s.
seconds_to_human() {
  local SECONDS_TOTAL="$1"
  local HUMAN_TEXT
  if (( SECONDS_TOTAL < 60 )); then
    HUMAN_TEXT="${SECONDS_TOTAL}s"
  elif (( SECONDS_TOTAL < 3600 )); then
    printf -v HUMAN_TEXT '%dm%02ds' $(( SECONDS_TOTAL / 60 )) $(( SECONDS_TOTAL % 60 ))
  elif (( SECONDS_TOTAL < 86400 )); then
    printf -v HUMAN_TEXT '%dh%02dm' $(( SECONDS_TOTAL / 3600 )) $(( SECONDS_TOTAL % 3600 / 60 ))
  else
    printf -v HUMAN_TEXT '%dd%02dh' $(( SECONDS_TOTAL / 86400 )) $(( SECONDS_TOTAL % 86400 / 3600 ))
  fi
  printf '%s' "${HUMAN_TEXT}"
}

# Prints the current time as epoch seconds.
now_epoch() {
  local EPOCH_NOW
  printf -v EPOCH_NOW '%(%s)T' -1
  printf '%s' "${EPOCH_NOW}"
}

# Prints an epoch time as local ISO 8601 with offset.
epoch_to_iso() {
  local EPOCH_VALUE="$1"
  local ISO_TEXT
  printf -v ISO_TEXT '%(%Y-%m-%dT%H:%M:%S%z)T' "${EPOCH_VALUE}"
  printf '%s' "${ISO_TEXT}"
}

# Converts free text into a short lowercase slug of [a-z0-9-].
slugify() {
  local SOURCE_TEXT="$1"
  local SLUG_TEXT="${SOURCE_TEXT,,}"
  SLUG_TEXT="${SLUG_TEXT//[^a-z0-9]/-}"
  while [[ "${SLUG_TEXT}" == *--* ]]; do
    SLUG_TEXT="${SLUG_TEXT//--/-}"
  done
  SLUG_TEXT="${SLUG_TEXT#-}"
  SLUG_TEXT="${SLUG_TEXT:0:40}"
  SLUG_TEXT="${SLUG_TEXT%-}"
  if [[ -z "${SLUG_TEXT}" ]]; then
    SLUG_TEXT="job"
  fi
  printf '%s' "${SLUG_TEXT}"
}

# Trims leading and trailing whitespace.
trim() {
  local TRIM_TEXT="$1"
  TRIM_TEXT="${TRIM_TEXT#"${TRIM_TEXT%%[![:space:]]*}"}"
  TRIM_TEXT="${TRIM_TEXT%"${TRIM_TEXT##*[![:space:]]}"}"
  printf '%s' "${TRIM_TEXT}"
}

# Returns 0 if the given process id is alive.
process_is_alive() {
  local PROCESS_ID="$1"
  [[ -n "${PROCESS_ID}" && "${PROCESS_ID}" =~ ^[0-9]+$ ]] && kill -0 "${PROCESS_ID}" 2>/dev/null
}

# Sleeps in the background and waits, so signal traps fire without waiting for sleep to finish.
interruptible_sleep() {
  local SLEEP_SECONDS="$1"
  sleep "${SLEEP_SECONDS}" &
  local SLEEP_PROCESS_ID=$!
  local SLEEP_STATUS=0
  wait "${SLEEP_PROCESS_ID}" || SLEEP_STATUS=$?
  if (( SLEEP_STATUS > 128 )) && process_is_alive "${SLEEP_PROCESS_ID}"; then
    kill "${SLEEP_PROCESS_ID}" 2>/dev/null || log_debug "sleep process ${SLEEP_PROCESS_ID} already gone"
  fi
}
