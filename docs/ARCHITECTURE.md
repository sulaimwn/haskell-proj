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
| `reckon-server` | `backend/` | JSON API. All domain logic, all database access, and all calls to the Claude API. Listens on `127.0.0.1` only. |
| Vite | `frontend/` | Serves the React app and proxies `/api` to the backend, so the browser sees one origin. |

The frontend has no business logic beyond display. Anything that affects
money happens in Haskell and is guarded by the database. Its one piece of
arithmetic on money is the width of a spending bar (`lib/bars.ts`), which is
never shown or summed.

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
    Server.hs             handlers, the status mapping for refusals, and the WAI Application (guards + Servant)
    Security.hs           WAI middleware: Host allowlist (DNS rebinding), JSON-only writes
    Views.hs              read-only queries behind the screens, in the API's own types
    Messages.hs           the wording of every refusal, shared by the CLI and the API
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
    Posting/Split.hs      pure: splitting a payment between me and friends (smart constructor, equal shares)
    People.hs             DB: people I share costs with, their receivable accounts, who owes what
    Sharing.hs            DB: splitRow (replace a row's entry with a split one)
    Report.hs             DB: spending by expense account (my share only)
    Rules/Language.hs     pure: the rule language: AST, megaparsec parser with line/column errors, renderer
    Rules/Eval.hs         pure: does a rule hold for a row (description, amount, kind of account)?
    Rules.hs              DB: save, check, delete rules (stored as canonical text); resolve them into the planner's Rule type
    Rules/History.hs      DB + pure: preview a rule against rows already imported, and apply it to the posted ones
    Anthropic.hs          the Claude Messages API client (raw HTTP): request builder, response parser, retries, redacted key
    Screenshot/Extraction.hs  pure: the schema and prompt sent to the model; strict validation of its reply; dates, years and amounts
    Screenshot/Align.hs   pure: joining overlapping screenshots of one scroll
    Screenshot/Match.hs   pure: which provisional row is which bank row (or later screenshot row)
    Screenshot/Score.hs   pure: scoring an extraction against a hand-labelled answer
    Screenshot/Store.hs   DB: store rows, post provisional entries, resolve them (confirm, supersede, release)
    Screenshot/Import.hs  orchestration: files -> media type -> hash -> model -> validate -> store, in one transaction
    Screenshot/Eval.hs    reads private/eval and prints scores
    Screenshot/Resolution.hs  how a provisional row stopped being provisional (stored as text)
  app/Main.hs             reckon-server executable
  cli/Main.hs             reckon-cli executable: import, post, rules, people, splits, owed, spending, screenshots, opening balance, checkpoints, reconcile
  codegen/Main.hs         reckon-codegen executable (writes generated.ts)
  test/                   hspec test suite
frontend/
  src/api/generated.ts    GENERATED from backend Api/Types.hs. Do not edit.
  src/api/client.ts       typed fetch wrappers, one per endpoint (+ ApiError, file -> base64)
  src/pages/              one component per screen: Accounts, Transactions, Spending, Receivables, Review, Rules, Import
  src/components/         shared pieces: Money, Notice, QueryState, forms, HealthBadge
  src/lib/                pure logic with tests: money.ts, route.ts, months.ts, bars.ts, plural.ts; hooks: useAction, useHashRoute
  src/testing.tsx         fake `fetch` and a render helper for component tests
db/
  migrations/             dbmate SQL migrations (source of truth for the schema)
  schema.sql              full current schema, rewritten by `make migrate` (appears with the first migration)
  init/                   runs once when the Postgres volume is created (creates reckon_test)
fixtures/                 FAKE data for tests and the demo (rbc/: fake RBC exports)
private/                  REAL data. Gitignored, never committed.
scripts/                  the bash behind every `make` target (reckon.sh runs any reckon-cli command)
docs/                     you are here
```

## The HTTP API and the screens (Phase 6)

Everything the CLI does is an endpoint (declared in `Reckon.Api`, handled in
`Reckon.Server`), and every JSON type is in `Reckon.Api.Types` and generated
into TypeScript.

| Endpoint | Answers / does | Backed by |
|---|---|---|
| `GET /api/accounts[?asOf=]` | each account: balance (the bank's sign), unposted rows, open provisional rows, latest checkpoint and its explanation | `Views.accountSummaries`, `Reconcile.reconcileAccount` |
| `GET /api/accounts/:last4/transactions` | entries on the account, newest first, filtered by `from`, `to`, `q`, `limit`; reversed entries and reversals are hidden (D063) | `Views.transactionsFor` |
| `GET /api/spending`, `/api/receivables`, `/api/ledger-accounts` | spending per expense account per month; who owes what; account names for the pickers | `Views.*`, `People.whoOwesWhat` |
| `GET /api/review` | rows left for review (with the reason and which friends a payment might be from), open provisional rows, import warnings | `Posting.reviewItems` (a dry run of posting), `Screenshot.Store`, `import_review_items` |
| `POST /api/imports/csv`, `/api/imports/screenshots` | import; files are base64 in JSON (D062) | `Import`, `Screenshot.Import` |
| `POST /api/post` | post every unposted row | `Posting.postPendingRows` |
| `POST /api/rows/:id/{settle,recategorize,split}`, `/api/provisional/:id/release` | the CLI's `post-row`, `recategorize`, `split-row`, `release-provisional` | `Posting`, `Sharing`, `Screenshot.Store` |
| `POST /api/people`, `/api/accounts/:last4/{opening-balance,checkpoints}` | add a friend; record balances (a checkpoint's result carries the reconciliation report) | `People`, `Reconcile` |
| `GET /api/rules`, `POST /api/rules`, `/api/rules/:id/delete` | list, save and delete rules (saving validates first: 422 with the line and column) | `Rules` |
| `POST /api/rules/check` | reads a rule and previews it against existing rows, **without saving**. A bad rule is a normal 200 answer with `problem {line, column, message}`, because the page calls it as you type | `Rules.checkRule`, `Rules.History.previewRule` |
| `POST /api/rules/apply` | moves the posted rows the rule would move | `Rules.History.applyRule` |

Reads are plain queries. Actions return `{message, details}`, the same
sentences the CLI prints (`Reckon.Messages`). A refusal is `{problem}`
with 400 (malformed input), 404 (no such row or account), 422 (the ledger
refused), 502 (the model's reply was unusable) or 503 (screenshot reading
isn't configured, i.e. no `ANTHROPIC_API_KEY`).

**Keeping a login-less API private (D061).** `Server.application` is
`hostGuard (jsonOnlyWrites (serve ...))`, and the server binds `RECKON_HOST`
(default `127.0.0.1`). So: other machines can't connect; a page on another
site can't use DNS rebinding (its requests carry another `Host`, answered 403);
and a cross-site form can't change anything (writes must be `application/json`,
answered 415, and a JSON write needs a CORS preflight that is never granted).

**The frontend** is six pages under a hash router (`#/accounts`,
`#/transactions/1234`, ...). Server data is cached by TanStack Query and every
successful action invalidates all of it (`useAction`), since any action can
change any page. A form turns what's typed into integer cents
(`parseAmountToCents` refuses "1.234" rather than rounding), the page sends
it, and the server's own sentences are shown verbatim in a `Notice`.

## Request flow (`GET /api/health`)

1. The browser requests `/api/health` from Vite, which proxies it to `:8080`.
2. Warp (the HTTP server) hands the request to the WAI `Application` built in
   `Reckon.Server.application`, which first runs the Host and JSON guards.
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
| Matched by a rule (the rule language, D067) | the rule's account, or a split with friends | First rule (by priority) whose conditions all hold |
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
| `posting_rules` | one rule per row as text in the rule language, in canonical form (UNIQUE), with priority. Replaced `categorization_rules` in Phase 7 (D068) | editable and deletable (configuration) |
| `statement_checkpoints` | a statement's closing balance for an account and date (UNIQUE per account and date), as the statement shows it | append-only |
| `opening_balances` | which journal entry is an account's opening balance, and its date | append-only; replaced by reversing the entry |

A row is **posted** when it has an evidence link to an entry that hasn't
been reversed. There's no status column to keep in step: "unposted" is a
query.

Signs: the ledger stores raw debits (+) and credits (−). Statements show the
**natural** balance (money in chequing, money owed on a card).
`naturalBalance` converts between them at the edges: opening balances and
checkpoints are entered natural, and reports print natural.

## Shared expenses (Phase 4)

Migration: `db/migrations/20260925090000_create_people.sql`. One new table,
`people` (name, `match_text`, receivable account), which is configuration and
may be edited. Everything else is built from entries that already exist.

```
scripts/reckon.sh add-person alex "ALEX SMITH"      creates receivable:alex
make post                                           a deposit mentioning ALEX SMITH is
                                                    left for review: "might be a repayment"
scripts/reckon.sh split-row 42 expense:food equal alex sam jo
                                                    the dinner's entry is reversed and re-posted
scripts/reckon.sh post-row 57 receivable:alex       Alex's e-Transfer settles his share
scripts/reckon.sh owed                              who owes what
scripts/reckon.sh spending 2026-03-01 2026-03-31    my share only
```

**A split is one entry** (D049). The $120 dinner (row #42, −$120.00 on the
chequing account) after `split-row 42 expense:food equal alex sam jo`:

| Account | amount_cents |
|---|---|
| `asset:rbc-chequing-1234` | −12000 |
| `expense:food` (my share) | +3000 |
| `receivable:alex` | +3000 |
| `receivable:sam` | +3000 |
| `receivable:jo` | +3000 |
| **sum** | **0** |

Still one entry, still linked to its one bank row, so the reconciliation
identity (Phase 3) holds unchanged: the bank account's line is the row.
Alex's later e-Transfer (+$30.00) is its own row and entry: `asset:rbc-chequing`
+3000, `receivable:alex` −3000, which brings his receivable to zero.

**Replacing an entry** (D051). `split-row` and `recategorize` reverse the
row's entry in effect (dated like the original) and post a new one. Nothing
is edited, and nothing is written if the request is invalid. A row whose
entry touches `asset:clearing` is refused: moving one leg of a pair alone
would leave clearing out of balance.

**Repayments** (D050, D053). The planner treats money *in* to a non-card
account whose description contains a person's `match_text` as a possible
repayment. It is left for review, not posted, and `make post` prints the
`post-row` command that applies it. Two people matching are both named.

**Spending** (D052) is the sum of `expense` accounts. A friend's share is in
their receivable (an asset) and transfers are in clearing, so neither can
count as spending.

## Screenshots (Phase 5)

Migration: `db/migrations/20260926090000_create_screenshots.sql`.

A screenshot of the RBC app is evidence of lower quality than a CSV, so it
lives in its own tables, is posted as a **provisional** entry, and gives way
when the bank's CSV arrives.

```
scripts/reckon.sh import-screenshots 1234 --taken 2026-02-20 top.png next.png   (one scroll, top first)
  1. no network: account exists? each file an image (by its first bytes)?
     already read (SHA-256)?  → those are skipped
  2. for each new image: Anthropic Messages API, reply constrained to a JSON Schema
     parseExtraction validates strictly; any problem → nothing stored, nothing posted
  3. alignScreenshots joins the overlapping screenshots (warns on ambiguity / no overlap)
  4. ONE transaction:
       insert screenshot_uploads, screenshot_rows (identity: account, date, fingerprint, occurrence)
       rows the bank's CSV already has              → resolved "already_in_csv", nothing posted
       older pending holds that these posted rows replace → hold reversed, "superseded_by_screenshot"
       everything else read with confidence         → "(provisional) ..." entry + screenshot_entry_evidence
make post (later, after the bank's CSV is imported)
  confirmProvisionalRows: planMatches provisional rows vs the CSV rows → each match:
       provisional entry reversed (dated like the original), resolved "confirmed_by_csv"
       then the CSV row is posted the normal way
```

**What the model does and doesn't do** (D055). It copies the date, description and amount as
displayed, a direction, pending or posted, a running balance if shown, whether it was unsure, and
whether the row is cut off. Dates become real dates, the year is worked out, amounts become
exact cents, and anything off is refused, all in `Reckon.Screenshot.Extraction`, which is pure.

**Tables:**

| Table | Holds | Mutable? |
|---|---|---|
| `screenshot_uploads` | one per image: SHA-256 (UNIQUE), file name, account, day taken, model, the validated reply | append-only |
| `screenshot_rows` | each transaction read, after joining: date, description, amount, running balance, pending, uncertain, fingerprint, occurrence | append-only |
| `screenshot_entry_evidence` | which provisional entry was posted from which row | append-only |
| `provisional_resolutions` | how a row stopped being provisional: `confirmed_by_csv`, `already_in_csv`, `superseded_by_screenshot`, `released` (a CHECK ties each kind to the columns it needs; a CSV row can be claimed once) | append-only |

A screenshot row is **open** until it has a resolution. `scripts/reckon.sh provisional` lists the open ones.

**The reconciliation identity, extended** (D059): ledger balance = opening balance + posted CSV
rows + open provisional rows. A statement that disagrees by exactly the open provisional rows is
explained as such.

Worked example (`fixtures/screenshots`, taken 2026-02-20): `scroll-1` and `scroll-2` join into 8
rows, keeping both $4.50 coffees. Seven are posted provisionally (a $100.00 pending gas hold,
payroll, two coffees, grocery, hydro, an e-Transfer). The rent row the model wasn't sure of is kept
and not posted. When the bank's CSV arrives with the hold posted for $43.20, `make post` matches all
eight, reverses the seven entries, and posts the CSV rows: the ledger is exactly the CSV's.

## Rules (Phase 7)

A rule says where a bank row goes (D067). It is one line of text:

```
when description contains "TIM HORTONS" then categorize expense:coffee
when description starts with "UBER" and amount < -50.00 then categorize expense:transport
when description contains "DINNER" and account is credit card then split expense:food equally with alex, sam
```

```
 text ──parseRule──► Rule ──checkRule (friends exist?)──► renderRule ──► posting_rules.rule_text
                                                                          │ (canonical text; UNIQUE)
 posting:   loadRules ─ parse each stored text, look up accounts ─► Classify.Rule ─► planPosting
 preview:   loadHistory ─► previewRule (pure) ─► what each existing row would do   (nothing written)
 apply:     previewRule ─► for each "would move" row: recategorizeRow / splitRow   (reverse dated like the original, then post)
```

- **The language is pure** (`Rules.Language`): `parseRule`, `renderRule`, and `RuleProblem`.
  Mistakes are reported at the offending token. Round trip: `parseRule (renderRule r) == Right r`.
- **The database holds only the text.** There is no structured copy of a rule, so nothing can drift
  from it: posting, previewing and the Rules page all parse the stored text (D068). It is stored in
  canonical form, so the same rule written two ways is one row.
- **The planner uses a resolved `Classify.Rule`** (`label`, `conditions`, `outcome`), whose accounts
  are ids. An `Outcome` is `ToAccount` or `SplitWith`; a split posts one entry with a line per
  participant (`SplitByRule`), computed by `equalSplit`, so my share is the remainder (D049).
  A rule that matches but can't be carried out (a split of money in, an unknown friend, a share
  under a cent) is passed over and the next rule or the guess decides.
- **History** (`Rules.History`): `previewRule` (pure) classifies every existing row as *moves from X*,
  *already there*, *applies when posted*, or *can't change* (transfer legs, cancelled pairs, splits);
  `applyRule` moves exactly the *moves* rows through the same reverse-and-repost as `recategorize`,
  so no balance changes on any date (D069). It is a separate, explicit step: saving a rule never
  rewrites the past.

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
| A split's parts add up to the payment exactly; my share is the remainder; friends' shares are positive and unique | `Split` smart constructor (`mkSplit`) + `BalancedLines` + deferred trigger; example tests and two properties; DB property over random splits | Phase 4 |
| What a person owes = their receivable account's balance (shares minus repayments) | friend shares post to `receivable:<name>`; repayments credit it; tests settle one in full and one partly | Phase 4 |
| Reported spending counts only my share | spending sums `expense` accounts only (D052); test with a split dinner | Phase 4 |
| Re-posting a row never changes the bank account's balance on any date | reversal dated like the original (D051); test over every date of the month | Phase 4 |
| One leg of a transfer or cancelled pair can't be moved on its own | `repostRow` refuses an entry touching `asset:clearing`; tests | Phase 4 |
| Nothing the model says is trusted until validated: the year, exact cents and signs are worked out in code, and a reply with any bad row, extra field, or digit run that looks like an account number stores nothing | `parseExtraction` (pure) + all-or-nothing import transaction + tests over fake replies | Phase 5 |
| The API key is never printed, logged, stored, or sent anywhere but the API's header | `ApiKey` has a redacted `Show`; the request header is marked redacted; errors are built from the response, not the request; test asserts the key is in no error text | Phase 5 |
| Tests never call the real API | `Extractor` is a function; tests pass fakes, recorded replies in `fixtures/screenshots`, or an in-process stub server | Phase 5 |
| The same image is never read twice, and the same rows from overlapping screenshots are stored once, while genuinely identical rows are kept | SHA-256 UNIQUE; `alignScreenshots` (property over distinct rows, examples with identical rows); the (account, date, fingerprint, occurrence) key | Phase 5 |
| A provisional entry is always reversed, dated like the original, when it is resolved, so balances on every date are never double-counted | `reverseEntryOf` in confirm / supersede / release; tests check balances on every date after confirming | Phase 5 |
| A provisional row is resolved at most once, and a bank row confirms at most one provisional row | `provisional_resolutions` primary key + `UNIQUE (raw_bank_row_id)` + CHECK per kind; raw-SQL test | Phase 5 |
| A row is matched to a bank row only when unambiguous | `planMatches`: each is the other's only candidate, with identical rows matched as a group; property: matches are one to one | Phase 5 |
| Screenshot evidence is never modified | append-only triggers + raw-SQL tests | Phase 5 |
| Only the owner's own browser can read or change the ledger through the API | loopback bind (`RECKON_HOST`), `hostGuard` (403 for any other `Host`), `jsonOnlyWrites` (415 for anything but JSON); tests over a real Warp socket and on the middleware alone; mutation checks | Phase 6 |
| The UI never shows or sends a money amount that isn't an exact number of cents | integer cents on the wire; `formatCents` / `parseAmountToCents` (refuses more than two decimals), tested over 20,000 values and the refusals; a mutation check that parsing "1.234" fails tests | Phase 6 |
| A saved rule always parses, and is stored in one canonical form | `addRule` parses, validates (friends exist) and stores `renderRule`; `UNIQUE (rule_text)` + `CHECK` (raw-SQL test); property `parse . render == id`; a duplicate differing only in case or spacing is refused | Phase 7 |
| A rule that stops parsing never stops posting | `loadRules` skips it; test with a broken row inserted by raw SQL | Phase 7 |
| A rule never rewrites the past unless asked, and applying it changes no balance on any date | `previewRule` is read-only; `applyRule` reuses `repostRow` (reversal dated like the original); test compares the account's balance on every day before and after; mutation check | Phase 7 |
| A rule's split parts add up to the payment exactly | `equalSplit` → `BalancedLines` + deferred trigger; property over amounts | Phase 7 |
| Ledger balance = statement balance at each checkpoint, or the gap is explained | `make reconcile` / `checkpoint`: `explainReconciliation` names unposted rows, missing opening balance, duplicates, or uncovered days; end-to-end test | Phase 3 |

## CI

`.github/workflows/ci.yml` runs on every PR and on pushes to `main`.
`make check` runs the same checks locally.

| Job | Steps |
|---|---|
| Privacy guard and shell scripts | `check-private-data.sh --all`, shellcheck |
| Backend | cabal build with `-Werror` (dependency store cached by freeze-file hash), migrate a Postgres 17 service container, `cabal test`, `codegen.sh --check` |
| Frontend | `npm ci`, oxlint, `tsc -b` (strict), `vitest run`, `vite build` |

## Environments

Only local development exists so far. How the app is deployed (Phase 8) is
still open. The most likely option is the backend serving the built frontend
as static files, so production is a single process plus Postgres.
