#!/usr/bin/env bash
# Runs a reckon-cli command against the development database, e.g.
#   scripts/reckon.sh post
#   scripts/reckon.sh add-rule "TIM HORTONS" expense:coffee
#   scripts/reckon.sh checkpoint 1234 2026-01-31 1520.35
# Run it with no arguments to list every command.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

load_env
scripts/migrate.sh >/dev/null

(cd backend && cabal build -v0 exe:reckon-cli)
cli_binary="$(cd backend && cabal list-bin exe:reckon-cli)"
exec "$cli_binary" "$@"
