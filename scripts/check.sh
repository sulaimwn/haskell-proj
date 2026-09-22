#!/usr/bin/env bash
# Runs everything CI runs. Do this before pushing.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

load_env

log "Privacy guard"
scripts/check-private-data.sh --all

log "Shell scripts (shellcheck)"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck scripts/*.sh .githooks/pre-commit
else
  echo "shellcheck not installed; skipping (CI runs it). Install: sudo apt-get install shellcheck"
fi

log "Backend: build with warnings as errors"
(cd backend && cabal build all --ghc-options=-Werror)

scripts/migrate.sh >/dev/null
log "Backend: tests"
(cd backend && cabal test all --ghc-options=-Werror --test-show-details=direct)

log "Generated TypeScript is up to date"
scripts/codegen.sh --check

log "Frontend: lint, typecheck, build"
(cd frontend && npm run lint && npm run typecheck && npm run build)

log "All checks passed"
