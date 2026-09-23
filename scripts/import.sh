#!/usr/bin/env bash
# Imports a bank export into the development database.
# Usage: scripts/import.sh private/rbc-export.csv   (or: make import file=...)
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

if [[ $# -ne 1 ]]; then
  echo "usage: make import file=private/your-export.csv" >&2
  exit 2
fi
file="$1"
if [[ ! -f "$file" ]]; then
  echo "error: no such file: $file (paths are relative to the repo folder)" >&2
  exit 1
fi
case "$file" in
  private/*|./private/*) ;;
  *) log "Note: real exports belong in private/ so they can never be committed (docs/PRIVACY.md)" ;;
esac

load_env
scripts/migrate.sh >/dev/null

(cd backend && cabal build -v0 exe:reckon-cli)
cli_binary="$(cd backend && cabal list-bin exe:reckon-cli)"
"$cli_binary" import-rbc-csv "$file"
