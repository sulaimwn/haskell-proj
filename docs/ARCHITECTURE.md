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
    Posting/Classify.hs   pure: what each bank row is (rule, transfer leg, cancelled pair, card payment, uncategorized)
    Posting.hs            DB: postPendingRows (plan, reverse guesses, one entry per row), post-row, rules
    Reconcile/Explain.hs  pure: why a ledger balance and a statement balance differ
    Reconcile.hs          DB: opening balances, statement checkpoints, reconciliation reports
  app/Main.hs             reckon-server executable
  cli/Main.hs             reckon-cli executable: import, post, rules, opening balance, checkpoints, reconcile
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
scripts/                  the bash behind every `make` target (reckon.sh runs any reckon-cli command)
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
Importing never creates journal entries. Posting (below) does.

## Posting and reconciliation (Phase 3)

Migration: `db/migrations/20260924090000_create_posting_and_reconciliation.sql`.

The bank rows are the **evidence**. Posting turns each one into a journal
entry, and reconciliation proves the result matches the bank's statements.

```
make import file=...     → raw_bank_rows (evidence, never modified)
make post
  └─ reckon-cli post ── one transaction ──────────────────────────────────────────────┐
       1. create the well-known accounts on first use (asset:clearing, ...)          │
       2. load unposted rows (no entry in effect), plus rows posted on a guess       │
          that are recent enough to pair with them                                   │
       3. planPosting (pure): cancelled pairs → transfer pairs → rules →             │
          untracked-card payments → uncategorized; ambiguous rows → review           │
       4. for each guess that now pairs: reverse its old entry, dated the same       │
       5. for each posting: one journal entry + one journal_entry_evidence row       │
     COMMIT ─────────────────────────────────────────────────────────────────────────┘
scripts/reckon.sh opening-balance 1234 2026-01-31 1000.00   once per account
scripts/reckon.sh checkpoint 1234 2026-02-28 1552.43        per statement; prints the report
make reconcile                                              re-checks every checkpoint
```

**One row, one entry** (DECISIONS D039). A row's entry has two lines: the
row's amount on its bank's ledger account (`asset:rbc-chequing-1234`), and
the negated amount on a **counter account** chosen by the planner:

| What the row is | Counter account | How it's recognized |
|---|---|---|
| Half of a cancelled or refunded pair | `asset:clearing` | Same account, opposite amounts, within 45 days, one says CANCEL/REVERS/RETURN/DECLIN/REFUND. Checked first. |
| One leg of a transfer between my accounts | `asset:clearing` | Different accounts, opposite amounts, within 5 days |
| Matched by a categorization rule | the rule's account | First rule (by priority) whose text appears in the descriptions |
| Payment to a card reckon doesn't track | `liability:untracked-cards` | Money leaving a non-card account, "PAYMENT"/"PMT" plus a card name |
| Anything else | `expense:uncategorized` / `income:uncategorized` | By sign |
| Zero amount, or a pair that isn't unambiguous | *not posted*, left for review | Listed by `make post` with the row id |

**The clearing account** (D040). A transfer's two legs are separate entries
on their own dates, each against `asset:clearing`. So each bank account
matches its own statement on every date, the transfer never counts as
spending, and clearing's balance is the money in transit: zero once both
legs have landed.

**Pairing is all-or-nothing** (D041). Two rows pair only if each is the
other's *only* candidate. If a −$200 transfer has two +$200 candidates, all
three rows wait for a person (`scripts/reckon.sh post-row ROW_ID ACCOUNT`,
D046).

**Late pairing** (D042). If the chequing export arrives first, its payment
to the Visa is posted as a guess (untracked card or uncategorized). When the
Visa export arrives, the new row pairs with it: the guessed entry is
**reversed** (dated like the original, so no balance changes on any date)
and the row is re-posted against clearing.

**The reconciliation identity.** Because of the above, for every bank
account and every date:

```
ledger balance = opening balance + sum of its posted rows up to that date
```

So when the ledger disagrees with a statement, the cause is always in the
evidence: a row not posted yet, a missing opening balance, a duplicate
import, or days no export covered. `Reckon.Reconcile.Explain` checks for
each of these and reports which one closes the gap (D043).

Worked example (`fixtures/rbc/february-two-accounts.csv`, with rules
`EMPLOYER → income:job` and `HYDRO → expense:utilities`):

| Row | Account | Amount | Posted against |
|---|---|---|---|
| Feb 2 payroll | chequing | +1500.00 | `income:job` (rule) |
| Feb 3 payment to RBC VISA | chequing | −500.00 | `asset:clearing` (transfer with Feb 5) |
| Feb 4 e-Transfer sent | chequing | −30.00 | `asset:clearing` (cancelled pair with Feb 6) |
| Feb 5 PAYMENT - THANK YOU | Visa | +500.00 | `asset:clearing` (transfer with Feb 3) |
| Feb 6 e-Transfer cancelled | chequing | +30.00 | `asset:clearing` (cancelled pair with Feb 4) |
| Feb 8 coffee | Visa | −4.50 | `expense:uncategorized` |
| Feb 9 payment to AMEX | chequing | −120.00 | `liability:untracked-cards` |
| Feb 12 hydro | chequing | −85.40 | `expense:utilities` (rule) |
| Feb 14 transfer | chequing | −200.00 | review: two candidates |
| Feb 15 PAYMENT - THANK YOU | Visa | +200.00 | review |
| Feb 16 RETURN - BOOKSHOP | Visa | +200.00 | review |
| Feb 20 grocery | chequing | −42.17 | `expense:uncategorized` |

With a $1000.00 opening balance on Jan 31 and a Feb 28 statement of
$1552.43, the ledger shows $1752.43, and the report says the unposted
−$200.00 closes the gap. After `post-row` settles the three review rows, it
reports RECONCILED. `PostingSpec` runs exactly this.

**Tables:**

| Table | Holds | Mutable? |
|---|---|---|
| `journal_entry_evidence` | which raw bank row each posted entry came from (PK: entry, row) | append-only |
| `categorization_rules` | "description contains TEXT → account", with priority (TEXT stored upper-case, UNIQUE) | editable (configuration) |
| `statement_checkpoints` | a statement's closing balance for an account and date (UNIQUE per account and date), as the statement shows it | append-only |
| `opening_balances` | which journal entry is an account's opening balance, and its date | append-only; replaced by reversing the entry |

A row is **posted** when it has an evidence link to an entry that hasn't
been reversed. There's no status column to keep in step: "unposted" is a
query.

Signs: the ledger stores raw debits (+) and credits (−). Statements show the
**natural** balance (money in chequing, money owed on a card).
`naturalBalance` converts between them at the edges: opening balances and
checkpoints are entered natural, and reports print natural.

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
| Every posted entry comes from exactly one bank row, and a row has at most one entry in effect | `postRow` writes the entry and its `journal_entry_evidence` link together; posting only loads rows with no entry in effect; re-posting reverses first; idempotence test | Phase 3 |
| A bank account's ledger balance on any date = opening balance + its posted rows up to that date | one-row-one-entry (D039); re-posting reversals dated like the original (D042); DB test on every date of the fixture + hedgehog property over random exports; mutation check (reversal dated a day late fails) | Phase 3 |
| Transfers and cancellations never count as income or spending, and net to zero | both legs through `asset:clearing` (D040); `ClassifySpec` property: clearing sums to zero; DB property | Phase 3 |
| Rows are only paired when the pairing is unambiguous; otherwise a person decides | mutual-only-candidate rule in `pairUniquely` (D041); property: pairs are mutual, each new row handled exactly once; mutation check (removing the mutual check fails 5 tests) | Phase 3 |
| Evidence links, checkpoints and opening balances are never modified | append-only triggers + raw-SQL tests | Phase 3 |
| Ledger balance = statement balance at each checkpoint, or the gap is explained | `make reconcile` / `checkpoint`: `explainReconciliation` names unposted rows, missing opening balance, duplicates, or uncovered days; end-to-end test | Phase 3 |

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
