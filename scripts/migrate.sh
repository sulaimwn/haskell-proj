#!/usr/bin/env bash
# Applies pending SQL migrations (db/migrations) to the development database
# and the test database, starting Postgres first if needed. The development
# run also rewrites db/schema.sql, the full current schema, which is committed.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

load_env
require_command docker "Install Docker Engine: see docs/DEVELOPMENT.md."

docker compose --progress quiet up -d --wait db

# dbmate treats an empty migrations directory as an error.
if ! compgen -G "db/migrations/*.sql" >/dev/null; then
  log "No migrations yet; nothing to apply"
  exit 0
fi

log "Migrating development database (reckon)"
docker compose --progress quiet run --rm dbmate up

log "Migrating test database (reckon_test)"
docker compose --progress quiet run --rm \
  -e DATABASE_URL="postgres://reckon:reckon@db:5432/reckon_test?sslmode=disable" \
  dbmate --no-dump-schema up
