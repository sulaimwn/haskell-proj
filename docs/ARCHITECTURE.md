# Architecture

How reckon is put together **as of the current phase**. The target design is
in [SPEC.md](SPEC.md). The reasoning behind each choice is in
[DECISIONS.md](DECISIONS.md).

## Big picture

```
 Browser ──► Vite dev server (:5173) ──/api/*──► reckon-server (:8080) ──► Postgres 17 (:5433)
             React + TanStack Query      proxy    Haskell / Servant /       Docker container
                                                  persistent                schema from db/migrations
```

Three processes in development:

| Process | Code | Role |
|---|---|---|
| Postgres | `docker-compose.yml`, `db/` | The system of record. The schema is plain SQL migrations applied by dbmate. |
| `reckon-server` | `backend/` | JSON API. All domain logic, all database access, and (Phase 5) all calls to the Claude API. |
| Vite | `frontend/` | Serves the React app and proxies `/api` to the backend, so the browser sees one origin. |

The frontend has no business logic beyond display. Anything that affects
money happens in Haskell and is guarded by the database.

## Repository layout

```
backend/
  reckon.cabal            package definition: library, 2 executables, test suite
  cabal.project(.freeze)  pinned Hackage snapshot and exact dependency versions
  src/Reckon/
    Config.hs             env vars -> Config (pure parser + IO loader)
    Database.hs           connection pool, DB ping
    App.hs                AppEnv (shared deps) and AppM (handler monad)
    Api.hs                the HTTP API as a type (Servant NamedRoutes)
    Api/Types.hs          every JSON type on the wire + its TypeScript declaration
    Api/JsonOptions.hs    shared aeson encoding options
    Api/TypeScript.hs     renders Api.Types as a TypeScript module
    Server.hs             handlers and the WAI Application
    Money.hs              Cents: exact integer money
    Database/Schema.hs    persistent's description of the SQL tables
    Ledger/AccountType.hs asset | liability | income | expense | equity; display sign
    Ledger/Entry.hs       pure: BalancedLines (smart constructor), reversals
    Ledger.hs             DB operations: create account, post entry, post reversal, balance as of a date
    Bank.hs               BankAccountKind; Last4 (can only hold 4 digits)
    Import/RbcCsv.hs      pure: RBC CSV bytes -> [RbcRow] or line-numbered errors
    Import/Dedupe.hs      pure: fingerprints, occurrences, planImport (what's new, what to flag)
    Import.hs             DB: importRbcCsv (hash check, register account, lock, plan, insert)
  app/Main.hs             reckon-server executable
  cli/Main.hs             reckon-cli executable (`make import file=...`)
  codegen/Main.hs         reckon-codegen executable (writes generated.ts)
  test/                   hspec test suite
frontend/
  src/api/generated.ts    GENERATED from backend Api/Types.hs. Do not edit.
  src/api/client.ts       typed fetch wrappers, one per endpoint
  src/components/         React components
db/
  migrations/             dbmate SQL migrations (source of truth for the schema)
  schema.sql              full current schema, rewritten by `make migrate` (appears with the first migration)
  init/                   runs once when the Postgres volume is created (creates reckon_test)
fixtures/                 FAKE data for tests and the demo (rbc/: fake RBC exports)
private/                  REAL data. Gitignored, never committed.
scripts/                  the bash behind every `make` target
docs/                     you are here
```

## Request flow (`GET /api/health`)

1. The browser requests `/api/health` from Vite, which proxies it to `:8080`.
2. Warp (the HTTP server) hands the request to the WAI `Application` built in
   `Reckon.Server.application`.
3. Servant matches the path against the `Api` type and calls the `health`
   handler, which runs in `AppM` (it can read `AppEnv`).
4. The handler borrows a connection from the pool and runs `SELECT 1` with a
   2-second timeout. Failures become `DatabaseUnreachable` instead of errors.
5. Servant encodes the `HealthResponse` to JSON with the aeson instance.
6. On the frontend, TanStack Query caches the result and `HealthBadge`
   renders it. The response is typed by the generated `HealthResponse`
   interface.

## How frontend and backend types stay in sync

```
Api/Types.hs ──deriveJSONAndTypeScript──► aeson instances  (what the server actually sends)
     │                                  └► TS declarations ──reckon-codegen──► frontend/src/api/generated.ts
```

The JSON encoding and the TypeScript declaration come from **one** Template
Haskell splice with **one** set of options, so they cannot disagree.
`generated.ts` is committed so the frontend builds without a Haskell
toolchain. CI regenerates it and fails if the committed copy differs.

## Where the schema lives

The SQL migrations in `db/migrations/` are the source of truth, applied by
dbmate running in a container. persistent (the Haskell database library) is
used for connection pooling and queries, and **never** runs its
auto-migration. From Phase 1 on, the persistent entity definitions must match
the SQL, and integrity rules (balanced entries, append-only journal) are
enforced by the database itself: constraints and triggers.

## Data model (Phase 1)

Migration: `db/migrations/20260922210000_create_ledger.sql`. The full current
schema is in `db/schema.sql`.

```
ledger_accounts            journal_entries                      journal_lines
───────────────            ───────────────                      ─────────────
id                         id                                   id
name  "expense:food"       occurred_on        DATE              entry_id           → journal_entries
account_type  (5 values)   description                          ledger_account_id  → ledger_accounts
currency  = 'CAD'          reverses_entry_id  → journal_entries  amount_cents  BIGINT ≠ 0
created_at                   (UNIQUE: reversed at most once)      (debit +, credit −)
                           created_at
                           created_in_transaction
```

**Posting** (`Reckon.Ledger.postEntry`): one transaction inserts the entry,
then its lines. At COMMIT, deferred constraint triggers call
`check_journal_entry`, which requires at least two lines summing to zero.

**Correcting** (`postReversal`): a new entry with `reverses_entry_id` set,
whose lines negate the original's. The trigger also checks that the two
cancel exactly, account by account. Nothing is ever updated or deleted.

**Balance as of a date** (`accountBalanceAsOf`): the sum of an account's
lines whose entry `occurred_on <= date`, as a raw signed number.
`naturalBalance` converts it for display (liabilities, income and equity are
negated).

Worked example: a $4.50 coffee paid from chequing:

| Account | amount_cents |
|---|---|
| `expense:food` | +450 (debit) |
| `asset:rbc-chequing` | −450 (credit) |
| **sum** | **0** |

## Importing bank exports (Phase 2)

Migration: `db/migrations/20260923120000_create_imports.sql`.

```
make import file=private/export.csv
  └─ reckon-cli import-rbc-csv  ── one transaction ──────────────────────────────┐
       1. SHA-256 of the file. Already in import_batches? → "already imported", stop │
       2. parseRbcCsv: every row parses, or reject the file (line-numbered errors)   │
       3. insert import_batches                                                      │
       4. for each account in the file (kind + last 4 digits):                       │
            find or register bank_accounts (+ ledger account asset:rbc-chequing-NNNN)│
            SELECT ... FOR UPDATE on that bank_accounts row                          │
            load stored rows between the file's first and last date                  │
            planImport → rows to add, review flags                                   │
            insert raw_bank_rows, import_review_items, import_batch_coverage         │
     COMMIT ─────────────────────────────────────────────────────────────────────────┘
```

**Dedupe key** (DECISIONS D029): `(bank_account_id, transaction_date,
fingerprint, occurrence)`, UNIQUE. The fingerprint is the normalized
descriptions + cheque number + amount. The occurrence numbers identical rows
within a day. Worked example (the fixtures):

| | Jan 20 coffees | Jan 22 grocery | Jan 25 bookshop | Jan 31 coffees |
|---|---|---|---|---|
| `january.csv` (Jan 2–31, last day partial) | 2 → add #1, #2 | `#12` → add | add | 1 → add #1 |
| `mid-january-to-mid-february.csv` (Jan 15–Feb 13) | 2 → already present | renamed `#0012` → add, **flag possible duplicate** | absent, interior day → **flag missing** | 2 → add #2 only |

**Tables:**

| Table | Holds |
|---|---|
| `bank_accounts` | institution, kind, **last 4 digits only**, nickname, the mirroring ledger account |
| `import_batches` | one per imported file: source, SHA-256 (UNIQUE), file name |
| `import_batch_coverage` | per batch and account: first/last date, rows in file, rows added |
| `raw_bank_rows` | the evidence: date, descriptions, cheque number, amount (as the bank signs it), fingerprint, occurrence, first batch seen |
| `import_review_items` | `possible_duplicate` / `missing_from_newer_export`, pointing at the rows concerned |

All five are append-only apart from `bank_accounts` (DECISIONS D031).
Nothing here creates journal entries yet. That's Phase 3.

## Invariants

This section grows every phase. Each invariant lists how it is enforced.

| Invariant | Enforced by | Since |
|---|---|---|
| Frontend API types match the backend's JSON | single TH splice + committed codegen output + CI diff | Phase 0 |
| No real financial data in git | `.gitignore` + pre-commit hook + CI `privacy-guard` | Phase 0 |
| Every journal entry has ≥ 2 lines summing to zero | `BalancedLines` smart constructor (Haskell) + deferred constraint trigger (DB) + raw-SQL tests + hedgehog property | Phase 1 |
| The journal is append-only (no UPDATE, DELETE, TRUNCATE) | `BEFORE` triggers + raw-SQL tests | Phase 1 |
| A committed entry can never gain lines | `created_in_transaction` + `BEFORE INSERT` trigger on lines + raw-SQL test | Phase 1 |
| A reversal exactly cancels its original, at most once | trigger check + `UNIQUE (reverses_entry_id)` + `postReversal` + tests | Phase 1 |
| All balances together sum to zero; each equals the sum of its lines | follows from the above; checked by the hedgehog property against an in-memory model | Phase 1 |
| Money is never floating point | `Cents` newtype over `Int64` (no `Num`), `BIGINT` columns; CSV amounts parsed from text to cents | Phase 1–2 |
| An imported transaction is stored once, and identical same-day transactions are all kept | UNIQUE `(account, date, fingerprint, occurrence)` + `planImport` + hedgehog property over overlapping, shuffled, partial exports + raw-SQL test | Phase 2 |
| Re-importing the same file changes nothing | UNIQUE `import_batches.file_sha256` + test | Phase 2 |
| An import is all-or-nothing | one transaction; parser rejects the whole file on any bad row; test | Phase 2 |
| Imported evidence is never modified | append-only triggers + raw-SQL test | Phase 2 |
| Only the last 4 digits of an account number are stored | `Last4` smart constructor, parser discards the rest, `CHECK (last4 ~ '^[0-9]{4}$')`, test scanning every stored column | Phase 2 |
| Unclear dedupe cases go to a person, never guessed | `import_review_items` (possible duplicate, missing from newer export) | Phase 2 |
| Ledger balance = statement balance at each checkpoint | *Phase 3:* reconciliation report | planned |

## CI

`.github/workflows/ci.yml` runs on every PR and on pushes to `main`.
`make check` runs the same checks locally.

| Job | Steps |
|---|---|
| Privacy guard and shell scripts | `check-private-data.sh --all`, shellcheck |
| Backend | cabal build with `-Werror` (dependency store cached by freeze-file hash), migrate a Postgres 17 service container, `cabal test`, `codegen.sh --check` |
| Frontend | `npm ci`, oxlint, `tsc -b`, `vite build` |

## Environments

Only local development exists so far. How the app is deployed (Phase 8) is
still open. The most likely option is the backend serving the built frontend
as static files, so production is a single process plus Postgres.
