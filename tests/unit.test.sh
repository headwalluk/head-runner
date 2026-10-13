# shellcheck shell=bash
# Unit tests for helpers, frontmatter parsing and config validation.

test_duration_parsing() {
  load_library
  assert_equals 90 "$(duration_to_seconds 90)"
  assert_equals 45 "$(duration_to_seconds 45s)"
  assert_equals 1800 "$(duration_to_seconds 30m)"
  assert_equals 5400 "$(duration_to_seconds 1h30m)"
  assert_equals 86400 "$(duration_to_seconds 1d)"
  if duration_to_seconds 2x > /dev/null; then fail "2x should be rejected"; fi
  if duration_to_seconds "" > /dev/null; then fail "empty should be rejected"; fi
  if duration_to_seconds 30m1h > /dev/null; then fail "units out of order should be rejected"; fi
  assert_equals "1h05m" "$(seconds_to_human 3900)"
  assert_equals "42s" "$(seconds_to_human 42)"
}

test_slugify() {
  load_library
  assert_equals "fancy-plugin-one" "$(slugify "  Fancy Plugin: One! ")"
  assert_equals "job" "$(slugify "!!!")"
}

test_frontmatter_read_handles_quotes_comments_and_case() {
  load_library
  local SHEET="${TEST_SANDBOX_ROOT}/sheet.md"
  printf -- '---\nTitle: "Quoted # not a comment"\nengine: claude   # trailing comment\nCreate-Workdir: yes\n# full comment\nmodel: ~\n---\nbody\n' > "${SHEET}"
  local -A FIELDS=()
  local -a PROBLEMS=()
  frontmatter_load "${SHEET}" FIELDS PROBLEMS
  assert_equals 0 "${#PROBLEMS[@]}" "problem count"
  assert_equals "Quoted # not a comment" "${FIELDS[title]}"
  assert_equals "claude" "${FIELDS[engine]}"
  assert_equals "yes" "${FIELDS[create_workdir]}"
  assert_equals "" "${FIELDS[model]}"
  assert_equals "body" "$(frontmatter_body "${SHEET}")"
}

test_frontmatter_reports_bad_lines_duplicates_and_unclosed() {
  load_library
  local SHEET="${TEST_SANDBOX_ROOT}/sheet.md"
  printf -- '---\nengine: a\nengine: b\njust some text\n' > "${SHEET}"
  local -A FIELDS=()
  local -a PROBLEMS=()
  frontmatter_load "${SHEET}" FIELDS PROBLEMS
  assert_equals 3 "${#PROBLEMS[@]}" "problem count"
}

test_frontmatter_set_replaces_adds_and_creates() {
  load_library
  local SHEET="${TEST_SANDBOX_ROOT}/sheet.md"
  printf -- '---\npriority: 50\n---\n\nBody\n' > "${SHEET}"
  frontmatter_set "${SHEET}" priority 10
  frontmatter_set "${SHEET}" engine stub
  assert_equals $'priority\t10\nengine\tstub' "$(frontmatter_read "${SHEET}")"
  printf 'No frontmatter here\n' > "${SHEET}"
  frontmatter_set "${SHEET}" workdir /tmp
  assert_equals $'workdir\t/tmp' "$(frontmatter_read "${SHEET}")"
  assert_equals "No frontmatter here" "$(frontmatter_body "${SHEET}")"
}

test_config_reports_every_problem() {
  printf 'DEFAULT_TIMEOUT=forever\nDEFAULT_PRIORITY=high\nBOGUS_SETTING=1\nnot a setting\nDEFAULT_PERMISSIONS=yolo\n' > "${HEADRUN_CONFIG_DIR}/config"
  local COMMAND_OUTPUT
  if COMMAND_OUTPUT="$(headrun ls 2>&1)"; then fail "invalid config should fail"; fi
  assert_contains "${COMMAND_OUTPUT}" "DEFAULT_TIMEOUT"
  assert_contains "${COMMAND_OUTPUT}" "DEFAULT_PRIORITY"
  assert_contains "${COMMAND_OUTPUT}" "BOGUS_SETTING"
  assert_contains "${COMMAND_OUTPUT}" "expected KEY=value"
  assert_contains "${COMMAND_OUTPUT}" "DEFAULT_PERMISSIONS"
  assert_contains "${COMMAND_OUTPUT}" "5 problem(s)"
}

test_config_accepts_engine_bins_and_null_default() {
  printf 'DEFAULT_ENGINE=null\nCLAUDE_BIN=/opt/claude\nMY_TOOL_BIN=mytool\n' >> "${HEADRUN_CONFIG_DIR}/config"
  load_library
  assert_equals "" "${CFG_DEFAULT_ENGINE}"
  assert_equals "/opt/claude" "$(config_engine_bin claude)"
  assert_equals "mytool" "$(config_engine_bin my-tool)"
  assert_equals "opencode" "$(config_engine_bin opencode)"
}

test_every_config_key_is_documented() {
  local -a CONFIG_KEYS=()
  local CONFIG_KEY
  while IFS= read -r CONFIG_KEY; do
    CONFIG_KEYS+=("${CONFIG_KEY}")
  done < <(sed -n 's/^ *\([A-Z][A-Z_]*\)) CFG_.*/\1/p' "${REPOSITORY_ROOT}/lib/config.sh")
  (( ${#CONFIG_KEYS[@]} >= 10 )) || fail "found only ${#CONFIG_KEYS[@]} config keys in lib/config.sh"
  local CONFIGURATION_DOC SAMPLE_CONFIG
  CONFIGURATION_DOC="$(< "${REPOSITORY_ROOT}/docs/configuration.md")"
  SAMPLE_CONFIG="$(< "${REPOSITORY_ROOT}/share/config.sample")"
  for CONFIG_KEY in "${CONFIG_KEYS[@]}"; do
    assert_contains "${CONFIGURATION_DOC}" "| \`${CONFIG_KEY}\` |"
    assert_contains "${SAMPLE_CONFIG}" "${CONFIG_KEY}="
  done
}
