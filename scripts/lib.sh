#!/usr/bin/env bash
# Helpers shared by the other scripts. Source it, don't run it.

# Every script runs from the repository root.
cd "$(git rev-parse --show-toplevel)" || exit 1

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

require_command() {
  local command_name="$1" install_hint="$2"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: '$command_name' is not installed. $install_hint" >&2
    exit 1
  fi
}

# Creates .env from .env.example the first time, then exports every variable
# in it to this script and the processes it starts.
load_env() {
  if [[ ! -f .env ]]; then
    cp .env.example .env
    log "Created .env from .env.example"
  fi
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
  # docker-compose.yml runs dbmate as this user so files it writes are yours.
  export RECKON_UID RECKON_GID
  RECKON_UID="$(id -u)"
  RECKON_GID="$(id -g)"
}

# Points git at .githooks/ so the private-data check runs before every commit.
install_git_hooks() {
  if [[ "$(git config --get core.hooksPath || true)" != ".githooks" ]]; then
    git config core.hooksPath .githooks
    log "Installed git hooks (.githooks/pre-commit blocks committing private data)"
  fi
}

require_dev_tools() {
  require_command docker "Install Docker Engine: see docs/DEVELOPMENT.md."
  require_command cabal "Install GHC and cabal with ghcup: see docs/DEVELOPMENT.md."
  require_command npm "Install Node.js 22: see docs/DEVELOPMENT.md."
}
