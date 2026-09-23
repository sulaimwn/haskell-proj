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

Run the installer on its own. It asks a few questions. The defaults are
fine, including "Yes, prepend" when it offers to edit `~/.bashrc`.

```bash
curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh
```

Then load it into the current terminal and pin the versions this repo uses.
If the installer already picked them, as it did in September 2026, these
commands just confirm it:

```bash
source ~/.ghcup/env
ghcup install ghc 9.10.3 --set
ghcup install cabal 3.16.1.0 --set
cabal update
ghc --version     # The Glorious Glasgow Haskell Compilation System, version 9.10.3
```

Optional: `ghcup install hls --set` installs the Haskell Language Server. For
VS Code, add the "Haskell" extension, which uses it.

### 3. Node.js 22

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
export NVM_DIR="$HOME/.nvm"; source "$NVM_DIR/nvm.sh"
nvm install 22
node --version    # v22.x
```

### 4. Docker Engine

Follow <https://docs.docker.com/engine/install/ubuntu/>, then let your user run
Docker without sudo:

```bash
sudo usermod -aG docker "$USER"
```

**Log out and back in** so the group change applies, then check:
`docker run --rm hello-world` (it should work without sudo).

You don't need to install Postgres or dbmate. Both run in containers.

### 5. Get the code

```bash
git clone https://github.com/sulaimwn/haskell-proj.git
cd haskell-proj
```

Every `make` command below runs from this folder.

**New terminals:** the ghcup and nvm installers add themselves to
`~/.bashrc`, so a new terminal has `ghc`, `cabal` and `node` ready. In the
terminal you ran the installers in, run
`source ~/.ghcup/env; source ~/.nvm/nvm.sh` first.

## Running it

From the `haskell-proj` folder:

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

## Importing a real RBC export

1. In RBC Online Banking, download your transactions as CSV.
2. Save the file inside `private/` in this folder, e.g.
   `private/rbc-2026-01.csv`. `private/` is gitignored, and the pre-commit
   hook refuses to commit anything in it.
3. Run:

   ```bash
   make import file=private/rbc-2026-01.csv
   ```

The summary shows, per account, how many rows were added, how many were
already there (from an overlapping earlier export), and anything flagged
for review. Importing the same file twice does nothing. The first import of
an account registers it (e.g. "RBC Chequing ending 1234") with a matching
ledger account. Only the last 4 digits of the account number are stored.

If the file is rejected, the error lists each bad line. The parser's column
layout is an assumption until it has been checked against a real export
(docs/STATUS.md). Paste the error, with no amounts or names, to whoever is
working on the parser.

## From import to a reconciled ledger

Importing stores the bank's rows as evidence. These steps turn them into
journal entries and check the result against a statement. Every command
below is `scripts/reckon.sh COMMAND ...` (run it with no command to list
them). It builds the CLI if needed and uses the dev database.

1. **Import** each account's export (chequing, and any card you track):

   ```bash
   make import file=private/rbc-chequing-2026-02.csv
   ```

2. **Add rules** for things you recognize (optional, any time). A rule is
   "description contains TEXT → account". It applies to rows posted after
   it's added:

   ```bash
   scripts/reckon.sh add-rule PAYROLL income:job
   scripts/reckon.sh add-rule "TIM HORTONS" expense:coffee
   scripts/reckon.sh add-rule HYDRO expense:utilities 50     # lower priority number runs first (default 100)
   ```

   Account names start with `expense:`, `income:`, `asset:`, `liability:`,
   `receivable:` or `equity:`. New ones are created as needed.

3. **Post:**

   ```bash
   make post
   ```

   It prints what it did: rows categorized by a rule, transfer legs between
   your accounts, cancelled e-Transfers, payments to cards reckon doesn't
   track, and uncategorized rows. Rows it won't guess about are listed with
   their id:

   ```
   Left for review (3), not posted:
     #7  2026-02-14  -$200.00  Online Banking transfer - 5555  (looks like half of a transfer or cancellation, but which rows go together is ambiguous)
   ```

   Settle each one yourself, e.g. both legs of a transfer to the clearing
   account, or a refund to income:

   ```bash
   scripts/reckon.sh post-row 7 asset:clearing
   scripts/reckon.sh post-row 12 income:refunds
   ```

   Running `make post` again only posts what's new. Importing the other
   account's export later is fine: a payment first posted as "untracked
   card" is re-posted as a transfer once its other half arrives.

4. **Opening balance**, once per account. Take the balance from a statement
   dated **before** your first imported transaction (as the statement shows
   it: money in the account, or owed on a card):

   ```bash
   scripts/reckon.sh opening-balance 1234 2026-01-31 1000.00
   ```

   Recording another one replaces it (the old entry is reversed).

5. **Checkpoint** each statement's closing balance. It prints the
   reconciliation straight away:

   ```bash
   scripts/reckon.sh checkpoint 1234 2026-02-28 1552.43
   ```

   ```
   RBC Chequing ending 1234, statement dated 2026-02-28:
     statement $1552.43, ledger $1752.43
     These 1 imported row(s) aren't posted yet, and posting them closes the gap exactly (make post says why each is waiting):
       2026-02-14  -$200.00  Online Banking transfer - 5555
   ```

   Fix what it points at, then `make reconcile` re-checks every checkpoint.
   The goal is **RECONCILED** on each one.

`make db-psql` then `SELECT * FROM journal_entries ORDER BY id DESC LIMIT
20;` shows the raw entries if you want to look.

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
| `make import file=private/export.csv` | Import an RBC CSV export into the dev database |
| `make post` | Post imported rows to the journal (rules, transfers, cancellations); lists rows left for review |
| `make reconcile` | Compare the ledger with every recorded statement balance, and explain any gap |
| `scripts/reckon.sh COMMAND ...` | Any CLI command: `post-row`, `add-rule`, `opening-balance`, `checkpoint` (no arguments lists them) |
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
| `make: *** No rule to make target 'dev'` | You're not in the repo folder. `cd haskell-proj` first. |
| `ghcup: command not found`, `cabal: command not found` or `nvm: command not found` right after installing | The installer only updated `~/.bashrc`. Open a new terminal, or run `source ~/.ghcup/env; source ~/.nvm/nvm.sh`. |
| `cannot find -lgmp` (or `-lffi`, `-lz`) while building | Install the system packages from step 1. |
| `pg_config` / `libpq-fe.h` not found | `sudo apt-get install libpq-dev` |
| `permission denied ... docker.sock` | Add yourself to the `docker` group (step 4) and log in again. |
| Port 5433, 8080 or 5173 already in use | Change `RECKON_DB_PORT` / `RECKON_PORT` in `.env` (and the matching URLs). Vite's port is fixed at 5173 in `frontend/vite.config.ts`. |
| Badge says **API unreachable** | The backend isn't running or crashed. Check the `make dev` output. |
| Badge says **database unreachable** | Postgres is down: `make db-up`. |
| Tests fail with `TEST_DATABASE_URL is not set` | Run them with `make test`, not bare `cabal test`. |
| `make post` leaves rows "for review" | By design: it won't guess which rows go together. Settle each with `scripts/reckon.sh post-row ROW_ID ACCOUNT` (see "From import to a reconciled ledger"). |
| `opening-balance` says it must be before your first transaction | Use a statement balance from a date before the earliest imported row, or the first transaction would be counted twice. |
| `No imported bank account ends in 1234` | Import an export for that account first, and use its last 4 digits. |
| `reckon_test` database doesn't exist | It's created the first time the volume is initialized. If your volume predates that: `make db-psql`, then `CREATE DATABASE reckon_test;` |
