#!/usr/bin/env bash
# Runs the app on a fake dataset, in its own database (reckon_demo), so you
# can click through everything without any real data. Your development
# database is not touched.
#
#   scripts/demo.sh           start the demo (fills the database the first time)
#   scripts/demo.sh --reset   throw the demo database away and fill it again
#   scripts/demo.sh --check   refill it and verify the result, without starting the app
#                             (part of make check, so the demo can't quietly rot)
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

require_dev_tools
require_command node "Install Node.js 22: see docs/DEVELOPMENT.md."
load_env

docker compose --progress quiet up -d --wait db
demo_exists="$(docker compose exec -T db psql -U reckon -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = 'reckon_demo'")"

if [[ ("${1:-}" == "--reset" || "${1:-}" == "--check") && "$demo_exists" == "1" ]]; then
  log "Dropping the demo database"
  docker compose exec -T db psql -U reckon -d postgres -c "DROP DATABASE reckon_demo WITH (FORCE)" >/dev/null
  demo_exists=""
fi

if [[ "$demo_exists" != "1" ]]; then
  log "Creating the demo database"
  docker compose exec -T db psql -U reckon -d postgres -c "CREATE DATABASE reckon_demo" >/dev/null
  docker compose --progress quiet run --rm \
    -e DATABASE_URL="postgres://reckon:reckon@db:5432/reckon_demo?sslmode=disable" \
    dbmate --no-dump-schema up
  scripts/seed-demo.sh
else
  log "The demo database already exists (scripts/demo.sh --reset starts it over)"
fi

if [[ "${1:-}" == "--check" ]]; then
  exit 0
fi

log "Starting the app on the DEMO data (fake: your own database is not used)"
RECKON_DEMO=1 exec scripts/dev.sh
