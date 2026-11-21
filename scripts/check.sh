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

# A separate build directory: GHC does not recompile a module when only
# warning flags change, so in the normal dist-newstyle a module compiled earlier
# (say by `make test`) hides its warnings from -Werror. This directory only
# ever holds objects compiled with -Werror, as CI's clean build does.
werror_builddir=dist-newstyle-werror

log "Backend: build with warnings as errors"
(cd backend && cabal build all --enable-tests --ghc-options=-Werror --builddir="$werror_builddir")

scripts/migrate.sh >/dev/null
recreate_test_database
log "Backend: tests"
(cd backend && cabal test all --ghc-options=-Werror --builddir="$werror_builddir" --test-show-details=direct)

log "The demo dataset loads and comes out as described"
scripts/demo.sh --check

log "Generated TypeScript is up to date"
scripts/codegen.sh --check

log "Frontend: lint, typecheck, build"
(cd frontend && npm run lint && npm run typecheck && npm test && npm run build)

log "All checks passed"
