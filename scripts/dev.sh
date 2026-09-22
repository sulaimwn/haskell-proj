#!/usr/bin/env bash
# Starts the whole development stack: Postgres (in Docker), migrations, the
# Haskell API, and the Vite frontend. Ctrl-C stops the API and frontend;
# Postgres keeps running in the background (stop it with `make db-down`).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

require_dev_tools
load_env
install_git_hooks

scripts/migrate.sh

if [[ ! -d frontend/node_modules ]]; then
  log "Installing frontend dependencies"
  (cd frontend && npm ci)
fi

log "Building backend (the first build downloads and compiles dependencies; this takes a while)"
(cd backend && cabal build exe:reckon-server)
server_binary="$(cd backend && cabal list-bin exe:reckon-server)"

stop_children() {
  trap - INT TERM EXIT
  jobs -p | xargs -r kill 2>/dev/null || true
  wait 2>/dev/null || true
}
trap stop_children INT TERM EXIT

log "API:      http://localhost:${RECKON_PORT}/api/health"
log "Frontend: http://localhost:5173   (Ctrl-C stops both)"
# `exec` makes each background job *be* the server process, so stop_children
# kills the servers themselves rather than a wrapper shell.
(cd backend && exec "$server_binary") &
(cd frontend && exec ./node_modules/.bin/vite) &

# Exit (and stop the other one) as soon as either process stops.
wait -n
