# Development

How to set up a machine, run reckon, and do everyday tasks. The target is
**Ubuntu 24.04**. WSL2 on Windows uses exactly the same steps inside Ubuntu.

## One-time setup (Ubuntu)

### 1. System packages

```bash
sudo apt-get update
sudo apt-get install -y build-essential curl git pkg-config \
  libffi-dev libgmp-dev libncurses-dev zlib1g-dev libpq-dev shellcheck
```

`libffi`, `libgmp`, `libncurses` and `zlib` are what GHC needs. `libpq-dev`
is the Postgres client library that `persistent-postgresql` links against.
`shellcheck` lints the bash scripts (`make check` skips that step if it's
missing, but CI doesn't).

### 2. Haskell (GHC + cabal) via ghcup

```bash
curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh
# restart the shell (or `source ~/.ghcup/env`), then pin the versions this repo uses:
ghcup install ghc 9.10.3 --set
ghcup install cabal 3.16.1.0 --set
ghcup install hls --set   # optional: Haskell Language Server for your editor
cabal update
```

For VS Code, install the "Haskell" extension. It uses the HLS that ghcup
installed.

### 3. Node.js 22

Using nvm (the repo's `.nvmrc` pins the major version):

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
# restart the shell, then from the repo root:
nvm install && nvm use
```

### 4. Docker Engine

Follow <https://docs.docker.com/engine/install/ubuntu/>, then let your user run
Docker without sudo:

```bash
sudo usermod -aG docker "$USER"   # log out and back in afterwards
docker run --rm hello-world        # should work without sudo
```

You don't need to install Postgres or dbmate. Both run in containers.

## Running it

```bash
make dev
```

This command:

1. creates `.env` from `.env.example` if it doesn't exist
2. installs the git pre-commit hook (the private-data guard)
3. starts Postgres in Docker, on `localhost:5433`
4. applies migrations to the dev and test databases
5. installs frontend dependencies if needed
6. builds and starts the API on <http://localhost:8080>
7. starts the Vite dev server on <http://localhost:5173>

Open <http://localhost:5173>. The badge in the top right should read
**API ok · database ok**. Ctrl-C stops the API and the frontend. Postgres keeps
running; `make db-down` stops it.

**The first build takes 10–20 minutes** because cabal compiles every Haskell
dependency. After that, builds are incremental and take seconds.

## Everyday commands

Run `make` with no arguments to see them all.

| Command | What it does |
|---|---|
| `make dev` | Start everything (see above) |
| `make test` | Backend test suite. Recreates and migrates `reckon_test` first (the journal is append-only, so tests can't clean up) |
| `make check` | Everything CI runs. **Run before pushing.** |
| `make codegen` | Regenerate `frontend/src/api/generated.ts` after changing API types |
| `make migration name=create_ledger_accounts` | Create a new timestamped SQL migration in `db/migrations/` |
| `make migrate` | Apply pending migrations to the dev and test databases |
| `make db-psql` | psql shell on the dev database |
| `make db-down` | Stop Postgres (data is kept in a Docker volume) |
| `make db-destroy` | Delete the database volume, including everything imported (asks first) |
| `make hooks` | (Re)install the pre-commit hook |

Run a subset of backend tests: `scripts/test.sh --match "GET /api/health"`.

## Environment variables

Defined in `.env` (copied from `.env.example`). The scripts export them.

| Variable | Used by | Default |
|---|---|---|
| `DATABASE_URL` | backend | `postgres://reckon:reckon@localhost:5433/reckon?sslmode=disable` |
| `TEST_DATABASE_URL` | backend tests | same server, database `reckon_test` |
| `RECKON_PORT` | backend, Vite proxy | `8080` |
| `RECKON_DB_PORT` | docker-compose | `5433` |
| `ANTHROPIC_API_KEY` | backend (Phase 5) | unset |

## Common workflows

**Changing an API type:** edit `backend/src/Reckon/Api/Types.hs`, run
`make codegen`, then fix whatever the TypeScript compiler now complains about.
CI fails if `generated.ts` is stale.

**Changing the schema:** `make migration name=...`, write the `-- migrate:up`
and `-- migrate:down` SQL, then `make migrate`. Commit the migration **and**
the regenerated `db/schema.sql`. Never edit a migration that has already been
merged; add a new one.

**Before pushing:** `make check`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `cannot find -lgmp` (or `-lffi`, `-lz`) while building | Install the system packages from step 1. |
| `pg_config` / `libpq-fe.h` not found | `sudo apt-get install libpq-dev` |
| `permission denied ... docker.sock` | Add yourself to the `docker` group (step 4) and log in again. |
| Port 5433, 8080 or 5173 already in use | Change `RECKON_DB_PORT` / `RECKON_PORT` in `.env` (and the matching URLs). Vite's port is fixed at 5173 in `frontend/vite.config.ts`. |
| Badge says **API unreachable** | The backend isn't running or crashed. Check the `make dev` output. |
| Badge says **database unreachable** | Postgres is down: `make db-up`. |
| Tests fail with `TEST_DATABASE_URL is not set` | Run them with `make test`, not bare `cabal test`. |
| `reckon_test` database doesn't exist | It's created the first time the volume is initialized. If your volume predates that: `make db-psql`, then `CREATE DATABASE reckon_test;` |
