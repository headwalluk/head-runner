# shellcheck shell=bash
# Jobsheet frontmatter: a flat "key: value" subset of YAML between --- fences.

# Prints "key<TAB>value" for each frontmatter entry; problems are printed as "!<TAB>message".
frontmatter_read() {
  local JOBSHEET_FILE="$1"
  awk '
    function trim(text) { sub(/^[ \t\r]+/, "", text); sub(/[ \t\r]+$/, "", text); return text }
    NR == 1 {
      sub(/^\357\273\277/, "")
      if ($0 !~ /^---[ \t\r]*$/) { exit 0 }
      in_block = 1
      next
    }
    in_block && /^(---|\.\.\.)[ \t\r]*$/ { closed = 1; exit 0 }
    in_block {
      line = $0
      if (line ~ /^[ \t\r]*$/ || line ~ /^[ \t]*#/) { next }
      if (match(line, /^[A-Za-z_][A-Za-z0-9_-]*[ \t]*:/) == 0) {
        printf "!\tfrontmatter line %d is not \"key: value\": %s\n", NR, trim(line)
        next
      }
      key = substr(line, 1, RLENGTH - 1)
      value = trim(substr(line, RLENGTH + 1))
      key = tolower(trim(key))
      gsub(/-/, "_", key)
      if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) {
        value = substr(value, 2, length(value) - 2)
      } else {
        sub(/[ \t]+#.*$/, "", value)
      }
      if (value == "~" || value == "null") { value = "" }
      if (key in seen) { printf "!\tfrontmatter key \"%s\" appears more than once\n", key }
      seen[key] = 1
      printf "%s\t%s\n", key, value
    }
    END {
      if (in_block && !closed) { printf "!\tfrontmatter has no closing --- line\n" }
    }
  ' "${JOBSHEET_FILE}"
}

# Loads frontmatter into the named associative array; problems go into the named indexed array.
frontmatter_load() {
  local JOBSHEET_FILE="$1"
  local -n FIELDS_REFERENCE="$2"
  local -n PROBLEMS_REFERENCE="$3"
  local FIELD_KEY FIELD_VALUE
  while IFS=$'\t' read -r FIELD_KEY FIELD_VALUE; do
    if [[ "${FIELD_KEY}" == "!" ]]; then
      PROBLEMS_REFERENCE+=("${FIELD_VALUE}")
    else
      FIELDS_REFERENCE["${FIELD_KEY}"]="${FIELD_VALUE}"
    fi
  done < <(frontmatter_read "${JOBSHEET_FILE}")
}

# Returns 0 if the file starts with a frontmatter fence.
frontmatter_present() {
  local JOBSHEET_FILE="$1"
  local FIRST_LINE=""
  IFS= read -r FIRST_LINE < "${JOBSHEET_FILE}" || [[ -n "${FIRST_LINE}" ]]
  FIRST_LINE="${FIRST_LINE#$'\xef\xbb\xbf'}"
  [[ "${FIRST_LINE%$'\r'}" =~ ^---[[:space:]]*$ ]]
}

# Prints the document body after the frontmatter, without leading blank lines.
frontmatter_body() {
  local JOBSHEET_FILE="$1"
  awk '
    NR == 1 && /^(\357\273\277)?---[ \t\r]*$/ { in_block = 1; next }
    in_block && /^(---|\.\.\.)[ \t\r]*$/ { in_block = 0; next }
    in_block { next }
    !started && /^[ \t\r]*$/ { next }
    { started = 1; print }
  ' "${JOBSHEET_FILE}"
}

# Sets (or adds) a frontmatter key in place, creating the frontmatter block if absent.
frontmatter_set() {
  local JOBSHEET_FILE="$1"
  local FIELD_KEY="$2"
  local FIELD_VALUE="$3"
  local TEMPORARY_FILE="${JOBSHEET_FILE}.tmp.$$"
  if [[ "${FIELD_VALUE}" == *[[:space:]]#* || "${FIELD_VALUE}" == [\"\']* || "${FIELD_VALUE}" != "$(trim "${FIELD_VALUE}")" ]]; then
    FIELD_VALUE="\"${FIELD_VALUE}\""
  fi

  if frontmatter_present "${JOBSHEET_FILE}"; then
    # Values travel through ENVIRON because awk -v would interpret backslash escapes.
    HEADRUN_FIELD_KEY="${FIELD_KEY}" HEADRUN_FIELD_VALUE="${FIELD_VALUE}" awk '
      BEGIN { field_key = ENVIRON["HEADRUN_FIELD_KEY"]; field_value = ENVIRON["HEADRUN_FIELD_VALUE"] }
      function normalise(text) { text = tolower(text); gsub(/-/, "_", text); return text }
      NR == 1 { in_block = 1; print; next }
      in_block && /^(---|\.\.\.)[ \t\r]*$/ {
        if (!replaced) { printf "%s: %s\n", field_key, field_value }
        in_block = 0; replaced = 1; print; next
      }
      in_block && match($0, /^[A-Za-z_][A-Za-z0-9_-]*[ \t]*:/) {
        existing_key = substr($0, 1, RLENGTH - 1)
        sub(/[ \t]+$/, "", existing_key)
        if (normalise(existing_key) == normalise(field_key)) {
          if (!replaced) { printf "%s: %s\n", field_key, field_value }
          replaced = 1
          next
        }
      }
      { print }
    ' "${JOBSHEET_FILE}" > "${TEMPORARY_FILE}"
  else
    {
      printf -- '---\n%s: %s\n---\n\n' "${FIELD_KEY}" "${FIELD_VALUE}"
      cat "${JOBSHEET_FILE}"
    } > "${TEMPORARY_FILE}"
  fi
  mv -f "${TEMPORARY_FILE}" "${JOBSHEET_FILE}"
}

# Prints the first Markdown heading in the body, without the leading hashes.
frontmatter_first_heading() {
  local JOBSHEET_FILE="$1"
  frontmatter_body "${JOBSHEET_FILE}" | awk '!found && /^#+[ \t]+/ { sub(/^#+[ \t]+/, ""); sub(/[ \t\r]+$/, ""); print; found = 1 }'
}

# Prints the value of one frontmatter key (tabs in the value preserved), or nothing.
frontmatter_value() {
  local JOBSHEET_FILE="$1"
  local FIELD_KEY="$2"
  frontmatter_read "${JOBSHEET_FILE}" | awk -v field_key="${FIELD_KEY}" '
    { tab_position = index($0, "\t") }
    !found && substr($0, 1, tab_position - 1) == field_key { print substr($0, tab_position + 1); found = 1 }
  '
}
