#!/usr/bin/env bash
# Runs the backend test suite against the migrated test database.
# Extra arguments go to hspec, e.g. `scripts/test.sh --match "GET /api/health"`.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

load_env
scripts/migrate.sh >/dev/null
recreate_test_database

# Pass each argument through separately so quoted patterns keep their spaces.
hspec_arguments=()
for argument in "$@"; do
  hspec_arguments+=("--test-option=$argument")
done

log "Running backend tests"
cd backend
cabal test --test-show-details=direct "${hspec_arguments[@]}"
