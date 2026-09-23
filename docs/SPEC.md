# reckon: product spec

This is the source of truth for **what** reckon is and the order it gets built
in. Where the code and this spec disagree, fix one of them and record why in
[DECISIONS.md](DECISIONS.md). Progress against it lives in [STATUS.md](STATUS.md).

## Core idea

My money lives in real bank accounts at RBC. reckon never moves money. It is a
double-entry ledger that records what happened, based on imported evidence
(CSV exports and screenshots of the RBC mobile app), and continuously proves
that its numbers match reality.

**The central invariant:** for every real bank account, the ledger balance as
of a statement date equals the balance on that statement. When it doesn't,
the app shows exactly which transactions explain the gap.

## Scope decisions made with the owner (Phase 0)

| Question | Answer | Consequence |
|---|---|---|
| Accounts tracked | RBC chequing only, for now | The schema supports many bank accounts, but the only real data is one chequing account. |
| Phase 3 scope | Keep the card and transfer features as specced, **and** add chequing-specific flows | Transfer pairing and card pending→posted are built and tested against fake fixtures. E-Transfers, bill payments and pending debit holds are added because they are what the real chequing data contains. |
| Currencies | CAD only | The ledger is single-currency. Each ledger account still records its currency, so a USD account can be added later without rewriting history. |
| Dev machine | Ubuntu (Windows 11 in the meantime) | Scripts are bash plus a Makefile. WSL2 works the same way. |
| Review flow | One PR per phase | Each phase ends with a PR and a summary. The next phase starts only after the owner reviews it. |

## Tech stack

- **Backend:** Haskell (GHC 9.10 via ghcup, cabal), Servant, persistent +
  esqueleto, aeson, http-client-tls (for the Claude API), hspec + hedgehog.
- **Database:** PostgreSQL 17 in docker-compose. The schema is hand-written SQL
  migrations run by dbmate. persistent entity definitions must match the SQL;
  persistent never auto-migrates.
- **Frontend:** React + Vite + TypeScript, TanStack Query. The API types are
  generated from the Haskell types and never written by hand.

## Conventions

- Descriptive names, short comments explaining intent.
- **Money is never floating point.** It is a `Cents` newtype over `Int64` in
  Haskell, `BIGINT` in SQL, and integer cents in TypeScript, formatted only
  at display time.
- Invalid states are hard to represent: separate types for pending and posted
  transactions, one newtype per ID type.
- Docs are updated in the same change as the code (see CLAUDE.md).

## Privacy rules (non-negotiable)

See [PRIVACY.md](PRIVACY.md). In short: store only the last 4 digits of any
account number, keep real data in `/private` (gitignored, blocked by a
pre-commit hook and by CI), keep only fake data in `/fixtures`, and keep the
Anthropic API key in `.env`. The key is used only by the backend.

## Ledger model

Ledger accounts have a type: asset, liability, income, expense, or equity.
Examples:

- `asset:rbc-chequing` (linked to a real bank account)
- `expense:food`, `expense:transport`, `expense:subscriptions`, ...
- `income:job`, `income:other`
- `receivable:<friend>` (money a friend owes me)
- `equity:opening-balance`

Journal entries are **append-only**: never updated or deleted. Corrections are
reversing entries that reference the entry they reverse. Every entry's lines
sum to zero, enforced by a deferred constraint trigger in the database, not
only in application code.

### Suggested tables (to be refined, with changes explained)

As built so far, see [ARCHITECTURE.md](ARCHITECTURE.md#data-model-phase-1).
One refinement: `journal_entries` has no `status` column, because the journal is
append-only. Confirmation of provisional entries will be its own table (DECISIONS D025).
Phase 2 added `bank_accounts`, `import_batches`, `import_batch_coverage`, `raw_bank_rows`
and `import_review_items`. `raw_bank_rows` uses `occurrence` instead of
`position_within_day`, and omits status and screenshot-only columns for now
(DECISIONS D029, D035).

| Table | Purpose |
|---|---|
| `bank_accounts` | institution, nickname, account_kind (chequing/savings/credit_card), last4, currency, linked ledger account |
| `ledger_accounts` | name, account_type, currency |
| `import_batches` | source (csv, screenshot), file sha256, imported_at, status |
| `raw_bank_rows` | the evidence: batch, bank account, date, description, amount_cents, running_balance_cents (nullable), is_pending, position_within_day, source, confidence, status (unmatched, matched, superseded, rejected) |
| `journal_entries` | occurred_on, description, status (provisional, confirmed), reverses_entry_id (nullable), created_at |
| `journal_lines` | entry_id, ledger_account_id, amount_cents (signed) |
| `raw_row_links` | which raw rows are evidence for which journal entry |
| `statement_checkpoints` | bank_account_id, as_of_date, statement_balance_cents |
| `screenshot_uploads` | sha256, uploaded_at, model id used, raw extraction JSON, status |
| `jobs` | Postgres-backed job queue (`FOR UPDATE SKIP LOCKED`), retries, backoff |
| `categorization_rules` | stored rules for categorizing and splitting transactions |

## Phases

Each phase ends with a summary of what was built and the key design decisions.
The next phase starts only after the owner has reviewed it.

### Phase 0: Environment and skeleton

Monorepo (`/backend`, `/frontend`, `/db/migrations`, `/fixtures`,
`docker-compose.yml`), Postgres in Docker, dbmate, a Servant health endpoint,
a Vite React app that calls it, CLAUDE.md, and one command to start everything.

### Phase 1: Ledger core (no UI, no imports)

Migrations for `ledger_accounts`, `journal_entries`, `journal_lines`, including
the balance-enforcing trigger. Haskell domain types and functions to post
entries, post reversals, and compute an account's balance as of a date.
Tests:

- Hedgehog property: for any random sequence of valid entries and reversals,
  every entry sums to zero and the sum of all balances is zero.
- The database rejects an unbalanced entry even when the Haskell layer is
  bypassed (raw SQL).
- Reversing an entry returns the affected balances to their prior values.

### Phase 2: RBC CSV import

Parse RBC's CSV export. Assumed columns (to be verified against a real
export): Account Type, Account Number, Transaction Date, Cheque Number,
Description 1, Description 2, CAD$, USD$. Store only the last 4 digits of the
account number. Imports are idempotent:

- Re-importing the exact same file changes nothing (file hash).
- Overlapping date ranges (Jan 1–31, then Jan 15–Feb 15) must not duplicate
  rows. Bank CSVs have no stable transaction IDs, so identical transactions on
  the same day (two $4.50 coffees) must **not** be collapsed. Dedupe uses
  per-day ordering and counts, and flags ambiguous cases for review instead of
  guessing. The approach is explained to the owner in detail before it is
  implemented.

Fake RBC-format CSV fixtures cover these edge cases.

### Phase 3: Turning evidence into entries

- Simple rows become entries, categorized by rules where possible, otherwise
  into an uncategorized expense account.
- Transfer pairing: a transfer between two of my accounts appears in both
  exports, possibly on different days with different descriptions, and
  becomes **one** entry (not spending). Ambiguous pairs go to review.
- Pending vs posted: when a pending transaction posts with a different amount
  (a restaurant tip), the pending entry is reversed and the posted one
  recorded, preserving history.
- Statement checkpoints: I enter a statement balance for an account and date.
  The app reports whether the ledger matches and, if not, which rows explain
  the difference.

Chequing-specific flows (added with the owner in Phase 0, because the real
data is a chequing account). Exact RBC descriptions for each are verified
against real exports in Phase 2, not assumed.

- **Interac e-Transfers.** Recognize sent and received e-Transfers and
  extract the counterparty name where the description shows it. A received
  e-Transfer can be matched to a friend's open receivable (Phase 4 builds on
  this). Otherwise it is categorized by rules like any other row. A sent
  e-Transfer that is later **cancelled or declined** comes back as a
  separate credit. The two are paired and net to zero, so they don't count
  as spending or income. Any e-Transfer fee is its own expense line.
- **Bill payments.** Online bill payments to a payee (phone, hydro, a credit
  card issued by another bank) are recognized and categorized by payee via
  rules. Paying a credit card that reckon doesn't track goes to a dedicated
  `liability:untracked-cards` account rather than to spending, so card
  purchases aren't counted as spending at the moment they're paid off.
  (This is a design question to confirm when Phase 3 starts.)
- **Pending debit holds.** A debit purchase can first appear as a pending
  hold, most often at gas stations and hotels (a $100 hold that later posts
  at $43.20), and sometimes the hold is simply released and never posts. The
  hold is recorded as a provisional entry. When the posted transaction
  arrives, the hold is reversed and the posted amount recorded. A hold that
  drops off with no posting is reversed on its own. Holds are mostly visible
  in screenshots (Phase 5), since CSV exports may list only posted
  transactions (verify in Phase 2).

### Phase 4: Shared expenses and receivables

Split a transaction: a $120 dinner becomes $30 `expense:food` plus $30 to each
of three `receivable:<friend>` accounts. When a friend's e-Transfer later
appears in an import, it can be matched to their open receivable. Reported
spending reflects only my share.

### Phase 5: Screenshot ingestion with Claude

1. Upload screenshots of the RBC app's transaction list from the frontend.
   Exact duplicate images are rejected by hash.
2. The backend sends each image to the Anthropic Messages API, using
   schema-constrained JSON output, with the model ID set by an environment
   variable. The client is a small typed Haskell client on http-client-tls.
3. Extraction schema: the account as displayed, plus an ordered list of
   transactions (date as displayed, description, amount, direction, pending
   section, running balance if visible, an uncertainty flag). The model
   transcribes only what is visible, never guesses, never returns account
   numbers, and reports transactions cut off at the screen edge as partial.
4. The JSON is validated strictly in Haskell. The year is inferred
   deterministically in code (the most recent matching date not after the
   upload date), not by the model.
5. Overlapping screenshots from the same scroll are deduplicated by aligning
   the ordered lists and finding the overlapping run.
6. Extracted rows become `raw_bank_rows` (source = screenshot, low confidence)
   and are auto-posted as **provisional** journal entries.
7. A later CSV import is authoritative: matching provisional entries are
   confirmed, and unmatched or mismatched ones are flagged for review.
8. Tests never call the real API. They use recorded fake responses, including
   malformed ones, partial rows, and overlapping screenshots.
9. An evaluation script scores extraction against hand-labelled real
   screenshots in `/private/eval` (never committed): field-level accuracy, and
   rows missed or invented.

### Phase 6: Frontend

Accounts overview (balances, reconciliation status), import page, review
queue, transaction list (filter, split with friends), spending by category
per month (excluding transfers and friends' shares), receivables.

### Phase 7: Scheduled jobs and rules

- The Postgres job queue runs recurring checks: statement periods with no
  checkpoint, provisional entries with no CSV confirmation after N days, and
  upcoming due dates.
- A small categorization rule language, parsed and evaluated in Haskell, with
  validation errors shown in the frontend. Supports split rules and a
  "preview against past transactions" feature.

### Phase 8: Demo and README

A seed script with a fully fake dataset covering every hard case: duplicate
same-day coffees, overlapping imports, a transfer, a pending-to-posted tip
change, a split dinner and repayment, a USD purchase and refund, a cancelled
e-Transfer, a bill payment, a gas-station hold that posts lower and one that
is released, and overlapping screenshots. A README with the architecture, the invariants and
how each is enforced (types, database constraints, property tests), the dedupe
and screenshot-alignment approaches, extraction accuracy results, and known
limitations.
