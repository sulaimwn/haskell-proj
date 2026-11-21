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

The API listens on `127.0.0.1` only and answers only to the host names
`localhost`, `127.0.0.1` and `[::1]`, because it has no login (D061). So open
the app as `localhost` (not by your LAN address, which gets a 403), and don't
change `RECKON_HOST` / `RECKON_ALLOWED_HOSTS` unless you mean to expose it.

## Using the web UI

The same loop as the command line below, with buttons:

1. **Import** a bank CSV (the file picker), then **Accounts → Post imported rows**.
2. **Review** lists what posting wouldn't decide. Choose an account for each and press *Post*, or
   for a possible repayment press *Repayment from NAME*.
3. **Accounts → Record a statement** enters the statement's closing balance as the bank prints it
   (money in the account, or owed on a card); the card then shows *Reconciled* or a *Gap* with the
   reason. Set an **opening balance** from a statement dated before your first imported row.
4. **Rules** writes categorization rules (with a live preview); **Transactions → Change…** moves a posted row to another account or splits it with friends;
   **Receivables → Add a friend** first. **Spending** shows your share by category.
5. **Import → Screenshots** reads screenshots of the RBC app (needs `ANTHROPIC_API_KEY`);
   they appear as provisional rows on **Review** until the bank's CSV confirms them.

Amounts in forms are dollars and cents (`1,234.56`); more than two decimals is refused, not rounded.

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
   # or in the rule language (see "Writing rules" below):
   scripts/reckon.sh add-rule 'when description contains "UBER" and amount < -50.00 then categorize expense:transport'
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

## Writing rules

A rule is one line: `when CONDITION [and CONDITION ...] then ACTION`. In the web UI use the
**Rules** page, which reads the rule as you type, points at a mistake (line and column), and shows
which rows you've already imported it would match and what would happen to each. On the command line:

```bash
scripts/reckon.sh add-rule 'when description contains "TIM HORTONS" then categorize expense:coffee'
scripts/reckon.sh rules                        # list them, in the order they run
scripts/reckon.sh check-rule 'when ...'        # read it and preview the rows it would move (saves nothing)
scripts/reckon.sh apply-rule 'when ...'        # move the posted rows it would move (reverse and re-post)
scripts/reckon.sh delete-rule 3
```

| Part | Forms |
|---|---|
| Conditions | `description contains "TEXT"`, `description starts with "TEXT"`, `description ends with "TEXT"` (case and spacing don't matter); `amount < 50.00` (also `<= > >= = !=`; money out is negative, so `amount < 0` is a payment); `account is chequing`, `savings` or `credit card` |
| Actions | `categorize expense:coffee`; `split expense:food equally with alex, sam` (money out only; the friends must already be added) |
| Order | A lower priority number runs first (default 100); the first rule whose conditions all hold wins |

Saving a rule only affects rows posted from now on. `check-rule` shows what it would do to rows
already imported, and `apply-rule` (or the UI's "Save and move N posted rows") moves the posted
ones. The reasoning is in DECISIONS D067-D069.

## Reminders and due dates

The server checks for things you might forget once a day, in the background (a job in Postgres, D070):
a month with no statement balance recorded, screenshot rows the bank's export hasn't confirmed after a
week, and a due date coming up. They show on the **Review** page (dismiss one, or press *Check now*), and
on the command line:

```bash
scripts/reckon.sh run-checks                          # run the checks now
scripts/reckon.sh reminders                           # what is open
scripts/reckon.sh add-due-date "Visa payment" 15 5    # the 15th of every month, remind 5 days ahead
scripts/reckon.sh due-dates
scripts/reckon.sh delete-due-date 2
```

A reminder goes away by itself when its cause does (record the statement, import the CSV, the due date
passes). Months shorter than the day (the 31st in April) use their last day.

## Shared expenses

For payments you share with friends (dinner, groceries, a rented cabin).
Everything here is in `scripts/reckon.sh`, after the rows are imported and
posted.

1. **Add each person once.** The second argument is the text that appears in
   the description of *their* e-Transfers to you (take it from a real row
   in your export). It's matched ignoring case and extra spaces:

   ```bash
   scripts/reckon.sh add-person alex "ALEX SMITH"
   ```

   Names are lower-case letters, digits and hyphens. This creates
   `receivable:alex`, the account that holds what Alex owes you.

2. **Split a payment.** `make post` prints each row's number (the `#42` in
   its list of review items, or look in `make db-psql`: `SELECT id, ... FROM
   raw_bank_rows`). To share a $120 dinner equally between you, Alex and
   Sam, with your share in `expense:food`:

   ```bash
   scripts/reckon.sh split-row 42 expense:food equal alex sam
   ```

   Or with exact amounts. You keep the rest:

   ```bash
   scripts/reckon.sh split-row 42 expense:food alex=45.00 sam=25.00
   ```

   If the row was already posted (as "uncategorized", say), its entry is
   reversed and replaced. Transfer legs and cancelled pairs can't be split.

3. **Repayments.** When Alex's e-Transfer shows up, `make post` lists it
   under "Left for review" as a possible repayment, with the exact command.
   Apply it:

   ```bash
   scripts/reckon.sh post-row 57 receivable:alex
   ```

   If it wasn't a repayment (Alex sent rent money), post it to
   `income:...` instead.

4. **See who owes what**, and your real spending (only your share):

   ```bash
   scripts/reckon.sh owed
   scripts/reckon.sh spending 2026-03-01 2026-03-31
   ```

5. **Fix a category.** Rules only apply to rows posted *after* they exist.
   To move one already-posted row: `scripts/reckon.sh recategorize 42
   expense:restaurants`.

Typing an account name wrong (`expense:foood`) creates a new account, and
accounts can't be deleted (the journal is append-only), so check what you
type. `make db-psql` then `SELECT name FROM ledger_accounts ORDER BY name;`
lists them.

## Everyday commands

Run `make` with no arguments to see them all.

| Command | What it does |
|---|---|
| `make dev` | Start everything (see above) |
| `make test` | Backend test suite. Recreates and migrates `reckon_test` first (the journal is append-only, so tests can't clean up) |
| `cd frontend && npm test` | Frontend tests (Vitest). Also run by `make check` and CI. `npm run lint`, `npm run typecheck` and `npm run build` are the other checks |
| `make check` | Everything CI runs. **Run before pushing.** It builds the backend with `-Werror` in its own directory (`backend/dist-newstyle-werror`), so the first run after a change to the toolchain compiles the project twice (D073) |
| `make codegen` | Regenerate `frontend/src/api/generated.ts` after changing API types |
| `make migration name=create_ledger_accounts` | Create a new timestamped SQL migration in `db/migrations/` |
| `make migrate` | Apply pending migrations to the dev and test databases |
| `make import file=private/export.csv` | Import an RBC CSV export into the dev database |
| `make post` | Post imported rows to the journal (rules, transfers, cancellations); lists rows left for review |
| `make reconcile` | Compare the ledger with every recorded statement balance, and explain any gap |
| `make provisional` | Rows read from screenshots that no bank export has confirmed yet |
| `make owed` | What each person you share expenses with owes you |
| `scripts/reckon.sh COMMAND ...` | Any CLI command: `run-checks`, `reminders`, `add-due-date`, `post-row`, `recategorize`, `add-rule`, `rules`, `check-rule`, `apply-rule`, `delete-rule`, `add-person`, `split-row`, `spending`, `opening-balance`, `checkpoint` (no arguments lists them) |
| `make db-psql` | psql shell on the dev database |
| `make db-down` | Stop Postgres (data is kept in a Docker volume) |
| `make db-destroy` | Delete the database volume, including everything imported (asks first) |
| `make hooks` | (Re)install the pre-commit hook |

Run a subset of backend tests: `scripts/test.sh --match "GET /api/health"`.

## Reading screenshots

For the days a bank export doesn't cover yet (pending transactions, recent purchases). A
screenshot is read by Claude, so it's evidence of lower quality than a CSV: what it reads is posted
as a **provisional** entry, and the bank's CSV confirms or replaces it later.

1. **Put your key in `.env`** (gitignored): `ANTHROPIC_API_KEY=sk-ant-...`. Optionally
   `ANTHROPIC_MODEL=...` (default `claude-opus-5-5`). The key is only ever used by the backend,
   and screenshots are sent to Anthropic's API (see docs/PRIVACY.md: crop anything you don't want sent).
2. **Take screenshots of one scroll of the transactions list in the RBC app**, so that each one
   shares a few rows with the one before. Save them in `private/screenshots/`.
3. **Read them**, top of the list first, naming the account by its last 4 digits (it must
   already have had a CSV imported):

   ```bash
   scripts/reckon.sh import-screenshots 1234 private/screenshots/top.png private/screenshots/next.png
   scripts/reckon.sh import-screenshots 1234 --taken 2026-02-20 private/screenshots/*.png   # a screenshot from another day
   ```

   `--taken` is the day the screenshots were taken (default today): "Today", "Yesterday" and dates
   without a year ("Feb 14") are read against it. The command prints how many rows were read, how
   many were posted provisionally, and **warnings**: screenshots that share no rows (transactions
   between them may be missing), an ambiguous overlap, or the wrong order.
4. **See what's waiting on the bank:**

   ```bash
   scripts/reckon.sh provisional
   ```

5. **Import the bank's CSV later and run `make post`.** Each provisional row the CSV confirms is
   reversed and replaced by the CSV's own row, and `make post` says how many.
6. **A pending hold that never posted** (a gas-station hold that was released): `scripts/reckon.sh
   release-provisional ID` (the `#ID` from `provisional`). A hold that posted for a different amount
   is replaced automatically by the CSV row, or by a later screenshot showing it posted.

If the reading can't be used (a row with an unreadable date, a direction the model couldn't tell,
anything that looks like an account number) the whole thing is rejected, listing every problem, and
**nothing is stored**. Just run it again, or retake the screenshot.

**Checking how well it reads.** Put a few screenshots and hand-written labels in `private/eval/`:
`name.png` and `name.json`, where the label is

```json
{ "takenOn": "2026-02-20", "extraction": { "accountLabel": "Chequing", "transactions": [ ... ] } }
```

(`extraction` has the same shape the model returns, so a label can start as its own answer,
corrected by hand: see `fixtures/screenshots/scroll-1.json`.) Then
`scripts/reckon.sh eval-screenshots private/eval` prints, per screenshot and overall, how many
rows were found, missed and invented, and how many descriptions, sections and balances were right.
Try a cheaper model with `ANTHROPIC_MODEL=... scripts/reckon.sh eval-screenshots private/eval`
and compare.

## Environment variables

Defined in `.env` (copied from `.env.example`). The scripts export them.

| Variable | Used by | Default |
|---|---|---|
| `DATABASE_URL` | backend | `postgres://reckon:reckon@localhost:5433/reckon?sslmode=disable` |
| `TEST_DATABASE_URL` | backend tests | same server, database `reckon_test` |
| `RECKON_PORT` | backend, Vite proxy | `8080` |
| `RECKON_HOST` | backend: the address it listens on. Not for exposing the API: it has no login | `127.0.0.1` |
| `RECKON_ALLOWED_HOSTS` | backend: comma-separated `Host` names it answers to (403 otherwise) | `localhost,127.0.0.1,[::1]` |
| `RECKON_DB_PORT` | docker-compose | `5433` |
| `ANTHROPIC_API_KEY` | `import-screenshots`, `eval-screenshots` and the server's screenshot upload (the backend only; never the frontend, never logged) | unset (screenshots can't be read without it) |
| `ANTHROPIC_MODEL` | the same | `claude-opus-5-5` |
| `ANTHROPIC_BASE_URL` | the same. Only changed to point at a test stub. | `https://api.anthropic.com` |

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
| The page loads but everything says "This host name isn't allowed" (403) | You opened it by an address other than `localhost` / `127.0.0.1` / `[::1]`. Use `http://localhost:5173`, or add the name to `RECKON_ALLOWED_HOSTS` (and read D061 first). |
| Uploading screenshots says reading isn't configured (503) | The server has no `ANTHROPIC_API_KEY`. Put it in `.env` and restart `make dev`: it's read once, at startup. |
| Badge says **database unreachable** | Postgres is down: `make db-up`. |
| Tests fail with `TEST_DATABASE_URL is not set` | Run them with `make test`, not bare `cabal test`. |
| `make post` leaves rows "for review" | By design: it won't guess which rows go together. Settle each with `scripts/reckon.sh post-row ROW_ID ACCOUNT` (see "From import to a reconciled ledger"). |
| `opening-balance` says it must be before your first transaction | Use a statement balance from a date before the earliest imported row, or the first transaction would be counted twice. |
| `split-row` says there's no one called alex | Add them first: `scripts/reckon.sh add-person alex "THEIR NAME ON E-TRANSFERS"`. |
| `split-row` / `recategorize` says a row is one leg of a transfer | By design. Transfers and cancelled pairs are two entries through `asset:clearing` that must stay together. |
| `ANTHROPIC_API_KEY is not set` | Add it to `.env` (see "Reading screenshots"). The key is read from the environment, never from the repo. |
| `import-screenshots` says the model's reading wasn't usable | By design: nothing was stored. The message lists each problem with its row. Run it again (readings vary), or retake the screenshot. |
| `The Anthropic API returned 401` / `403` | The key is wrong or lacks access to the model. Try another `ANTHROPIC_MODEL`. |
| `The Anthropic API returned 429` / `529` | Rate limited or overloaded. It already retried twice, so wait and run it again. |
| `WARNING: ... share no rows` | The screenshots don't overlap, so transactions between them may be missing. Retake them with a few rows in common. |
| `No imported bank account ends in 1234` | Import an export for that account first, and use its last 4 digits. |
| `reckon_test` database doesn't exist | It's created the first time the volume is initialized. If your volume predates that: `make db-psql`, then `CREATE DATABASE reckon_test;` |
