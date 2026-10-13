#!/usr/bin/env bash
# head-runner installer: curl -fsSL https://raw.githubusercontent.com/headwalluk/head-runner/main/install.sh | bash
#
# Environment:
#   HEADRUN_REF   git tag or branch to install (default: latest release, else main)
# Options:
#   --local       install from the directory containing this script (development)
#   --uninstall   remove the program and the ~/.local/bin/headrun link (keeps config and jobs)

set -o errexit -o nounset -o pipefail

REPOSITORY_SLUG="headwalluk/head-runner"
INSTALL_WORK_DIRECTORY=""
INSTALL_STAGING_DIRECTORY=""

# Prints an installer message.
say() {
  printf 'headrun-install: %s\n' "$*"
}

# Prints an error and exits.
abort() {
  printf 'headrun-install: error: %s\n' "$*" >&2
  exit 1
}

# Downloads a URL to stdout with curl or wget.
download() {
  local SOURCE_URL="$1"
  if command -v curl > /dev/null; then
    curl -fsSL "${SOURCE_URL}"
  elif command -v wget > /dev/null; then
    wget -qO- "${SOURCE_URL}"
  else
    abort "curl or wget is required"
  fi
}

# Prints the latest release tag, or nothing (with a note on stderr) if it cannot be determined.
latest_release_tag() {
  local RELEASE_JSON=""
  if ! RELEASE_JSON="$(download "https://api.github.com/repos/${REPOSITORY_SLUG}/releases/latest" 2>/dev/null)"; then
    say "could not look up the latest release (no releases yet, or the GitHub API is unavailable)" >&2
  else
    printf '%s' "${RELEASE_JSON}" | sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n 1p
  fi
}

# Removes the download and any half-built staging directory.
cleanup_install() {
  if [[ -n "${INSTALL_WORK_DIRECTORY}" ]]; then
    rm -rf -- "${INSTALL_WORK_DIRECTORY}"
  fi
  if [[ -n "${INSTALL_STAGING_DIRECTORY}" ]]; then
    rm -rf -- "${INSTALL_STAGING_DIRECTORY}"
  fi
}

# Checks the platform and required commands, reporting every missing item at once.
check_requirements() {
  local -a MISSING_ITEMS=()
  if [[ "$(uname -s)" != "Linux" ]]; then
    MISSING_ITEMS+=("Linux is required (found $(uname -s))")
  fi
  if (( BASH_VERSINFO[0] < 4 || ( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4 ) )); then
    MISSING_ITEMS+=("bash 4.4 or newer is required (found ${BASH_VERSION})")
  fi
  local REQUIRED_COMMAND
  for REQUIRED_COMMAND in flock setsid timeout awk tar mktemp tail sort readlink; do
    if ! command -v "${REQUIRED_COMMAND}" > /dev/null; then
      MISSING_ITEMS+=("${REQUIRED_COMMAND} is required (util-linux / coreutils)")
    fi
  done
  if (( ${#MISSING_ITEMS[@]} > 0 )); then
    local MISSING_ITEM
    for MISSING_ITEM in "${MISSING_ITEMS[@]}"; do
      printf 'headrun-install: error: %s\n' "${MISSING_ITEM}" >&2
    done
    exit 1
  fi
}

# Installs or upgrades head-runner for the current user.
main() {
  local INSTALL_MODE="remote"
  case "${1:-}" in
    --local) INSTALL_MODE="local" ;;
    --uninstall) INSTALL_MODE="uninstall" ;;
    "") ;;
    *) abort "unknown option: $1" ;;
  esac

  if [[ -z "${HOME:-}" ]]; then
    abort "HOME is not set"
  fi
  if (( EUID == 0 )); then
    say "warning: installing as root; head-runner is meant to run as an ordinary (ideally dedicated) user"
  fi

  local DATA_BASE="${XDG_DATA_HOME:-${HOME}/.local/share}"
  local CONFIG_BASE="${XDG_CONFIG_HOME:-${HOME}/.config}"
  local APP_DIRECTORY="${DATA_BASE}/headrun/app"
  local CONFIG_DIRECTORY="${CONFIG_BASE}/headrun"
  local BIN_DIRECTORY="${HOME}/.local/bin"
  local LINK_PATH="${BIN_DIRECTORY}/headrun"

  if [[ "${INSTALL_MODE}" == "uninstall" ]]; then
    rm -rf -- "${APP_DIRECTORY}"
    if [[ -L "${LINK_PATH}" ]]; then
      rm -f -- "${LINK_PATH}"
    fi
    say "removed ${APP_DIRECTORY} and ${LINK_PATH}"
    say "kept your config (${CONFIG_DIRECTORY}) and jobs (${DATA_BASE}/headrun/jobs)"
    exit 0
  fi

  check_requirements

  INSTALL_WORK_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/headrun-install.XXXXXX")"
  trap cleanup_install EXIT

  local SOURCE_DIRECTORY=""
  local SOURCE_LABEL=""
  if [[ "${INSTALL_MODE}" == "local" ]]; then
    SOURCE_DIRECTORY="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
    SOURCE_LABEL="local checkout ${SOURCE_DIRECTORY}"
  else
    local REQUESTED_REF="${HEADRUN_REF:-}"
    if [[ -z "${REQUESTED_REF}" ]]; then
      REQUESTED_REF="$(latest_release_tag)"
    fi
    if [[ -z "${REQUESTED_REF}" ]]; then
      say "installing the main branch"
    REQUESTED_REF="main"
    fi
    SOURCE_LABEL="${REPOSITORY_SLUG}@${REQUESTED_REF}"
    say "downloading ${SOURCE_LABEL}"
    download "https://github.com/${REPOSITORY_SLUG}/archive/${REQUESTED_REF}.tar.gz" > "${INSTALL_WORK_DIRECTORY}/source.tar.gz" \
      || abort "download failed for ${REQUESTED_REF}"
    mkdir "${INSTALL_WORK_DIRECTORY}/source"
    tar -xzf "${INSTALL_WORK_DIRECTORY}/source.tar.gz" -C "${INSTALL_WORK_DIRECTORY}/source" --strip-components=1
    SOURCE_DIRECTORY="${INSTALL_WORK_DIRECTORY}/source"
  fi

  if [[ ! -x "${SOURCE_DIRECTORY}/bin/headrun" ]]; then
    abort "the source does not contain bin/headrun: ${SOURCE_LABEL}"
  fi

  local STAGING_DIRECTORY="${APP_DIRECTORY}.new.$$"
  INSTALL_STAGING_DIRECTORY="${STAGING_DIRECTORY}"
  mkdir -p "$(dirname "${APP_DIRECTORY}")" "${BIN_DIRECTORY}"
  chmod 700 "$(dirname "${APP_DIRECTORY}")"
  mkdir "${STAGING_DIRECTORY}"
  local COPIED_ITEM
  for COPIED_ITEM in bin lib engines share docs VERSION LICENSE README.md CHANGELOG.md; do
    if [[ -e "${SOURCE_DIRECTORY}/${COPIED_ITEM}" ]]; then
      cp -R "${SOURCE_DIRECTORY}/${COPIED_ITEM}" "${STAGING_DIRECTORY}/"
    fi
  done

  local PREVIOUS_VERSION=""
  if [[ -f "${APP_DIRECTORY}/VERSION" ]]; then
    PREVIOUS_VERSION="$(< "${APP_DIRECTORY}/VERSION")"
    mv "${APP_DIRECTORY}" "${APP_DIRECTORY}.old.$$"
  fi
  mv "${STAGING_DIRECTORY}" "${APP_DIRECTORY}"
  INSTALL_STAGING_DIRECTORY=""
  rm -rf -- "${APP_DIRECTORY}.old.$$"
  ln -sfn "${APP_DIRECTORY}/bin/headrun" "${LINK_PATH}"

  mkdir -p "${CONFIG_DIRECTORY}"
  if [[ ! -f "${CONFIG_DIRECTORY}/config" ]]; then
    cp "${APP_DIRECTORY}/share/config.sample" "${CONFIG_DIRECTORY}/config"
    say "created ${CONFIG_DIRECTORY}/config"
  fi

  local INSTALLED_VERSION
  INSTALLED_VERSION="$(< "${APP_DIRECTORY}/VERSION")"
  if [[ -n "${PREVIOUS_VERSION}" ]]; then
    say "upgraded headrun ${PREVIOUS_VERSION} -> ${INSTALLED_VERSION} (${SOURCE_LABEL})"
  else
    say "installed headrun ${INSTALLED_VERSION} (${SOURCE_LABEL})"
  fi
  say "program: ${APP_DIRECTORY}"
  say "command: ${LINK_PATH}"

  if [[ ":${PATH}:" != *":${BIN_DIRECTORY}:"* ]]; then
    say "note: ${BIN_DIRECTORY} is not on your PATH; add this to ~/.bashrc or ~/.profile:"
    say "  export PATH=\"\${HOME}/.local/bin:\${PATH}\""
  fi

  local ENGINE_COMMAND
  local -a FOUND_ENGINES=()
  for ENGINE_COMMAND in claude opencode codex; do
    if command -v "${ENGINE_COMMAND}" > /dev/null; then
      FOUND_ENGINES+=("${ENGINE_COMMAND}")
    fi
  done
  if (( ${#FOUND_ENGINES[@]} > 0 )); then
    say "engines found on PATH: ${FOUND_ENGINES[*]}"
  else
    say "no agent CLIs found on PATH (claude, opencode, codex); the shell and stub engines still work"
  fi
  if ! command -v jq > /dev/null; then
    say "optional: install jq for readable Claude/OpenCode transcripts"
  fi
  say "next: headrun doctor"
}

main "$@"
