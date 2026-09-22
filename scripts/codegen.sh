#!/usr/bin/env bash
# Regenerates frontend/src/api/generated.ts from the Haskell API types.
# With --check, fails instead if the committed file is out of date (CI uses this).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

target="frontend/src/api/generated.ts"

(cd backend && cabal build -v0 exe:reckon-codegen)
codegen_binary="$(cd backend && cabal list-bin exe:reckon-codegen)"

if [[ "${1:-}" == "--check" ]]; then
  fresh="$(mktemp)"
  trap 'rm -f "$fresh"' EXIT
  "$codegen_binary" "$fresh" >/dev/null
  if ! diff -u "$target" "$fresh"; then
    echo "error: $target is out of date. Run \`make codegen\` and commit the result." >&2
    exit 1
  fi
  log "$target is up to date"
else
  "$codegen_binary" "$target"
fi
