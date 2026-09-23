#!/usr/bin/env bash
# Runs the backend test suite against the migrated test database.
# Extra arguments go to hspec, e.g. `scripts/test.sh --match "GET /api/health"`.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

load_env
scripts/migrate.sh >/dev/null

# The journal is append-only (even DELETE and TRUNCATE are rejected), so the
# test database can't be cleaned between runs. Recreate it from scratch
# instead: dropping a whole database bypasses table triggers.
log "Recreating the test database"
test_database_url="postgres://reckon:reckon@db:5432/reckon_test?sslmode=disable"
docker compose run --rm -e DATABASE_URL="$test_database_url" dbmate --no-dump-schema drop >/dev/null
docker compose run --rm -e DATABASE_URL="$test_database_url" dbmate --no-dump-schema up >/dev/null

# Pass each argument through separately so quoted patterns keep their spaces.
hspec_arguments=()
for argument in "$@"; do
  hspec_arguments+=("--test-option=$argument")
done

log "Running backend tests"
cd backend
cabal test --test-show-details=direct "${hspec_arguments[@]}"
