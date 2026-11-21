# Decisions

A log of design choices: the context, what was chosen, and what else was
considered. Newest at the bottom. When a decision is reversed, don't delete
it. Add a new entry that supersedes it and mark the old one **Superseded**.

Format: **D-number: title** (phase, status)

---

### D001: Monorepo with a self-contained backend package (Phase 0, accepted)

**Context:** Three languages, one product, one developer.
**Decision:** A single repo with `backend/` (its own `cabal.project`),
`frontend/`, `db/`, `fixtures/`, `scripts/`, `docs/`. The Makefile at the root
is the single entry point.
**Why:** One PR can change a Haskell type, the migration, and the React
component that uses them, and CI checks them together.
**Alternatives:** Separate repos. Rejected: the type-generation step would
need cross-repo publishing.

### D002: Pin GHC 9.10.3, cabal 3.16.1.0, and a Hackage snapshot (Phase 0, accepted)

**Context:** Haskell builds are only reproducible if the compiler and every
dependency version are pinned.
**Decision:** GHC 9.10.3 and cabal 3.16.1.0 (ghcup's "recommended" versions as
of Sept 2026). `index-state` in `cabal.project` and a committed
`cabal.project.freeze` pin every dependency exactly.
**Alternatives:** GHC 9.12/9.14 (newer, but ecosystem support lags), or Stack
with a Stackage LTS (a fine choice, but the spec calls for cabal).

### D003: GHC2024 with OverloadedRecordDot and DuplicateRecordFields (Phase 0, accepted)

**Context:** Classic Haskell records need prefixed field names
(`healthDatabaseStatus`) to avoid clashes, and JSON options to strip the
prefixes again.
**Decision:** Use the GHC2024 language edition, plus `DuplicateRecordFields` so
two records can share a field name, and `OverloadedRecordDot` for
`value.field` access. Field names are used verbatim as JSON keys.
**Why:** The Haskell field name, the JSON key, and the TypeScript property are
the same string. There's nothing to translate, and nothing to get wrong.

### D004: Servant with NamedRoutes (Phase 0, accepted)

**Decision:** Describe the API as a record of routes (`data Routes mode = ...`)
rather than a chain of `:<|>` alternatives.
**Why:** Handlers are matched to routes by field name, not by position, so
reordering routes can't silently wire the wrong handler, and compile errors
name the route.

### D005: Handlers run in `ReaderT AppEnv Handler` (Phase 0, accepted)

**Decision:** `type AppM = ReaderT AppEnv Handler`. `AppEnv` holds the config
and the database pool. Servant's `hoistServer` converts `AppM` to `Handler`.
**Why:** It's the standard "ReaderT pattern": dependencies are available
everywhere without passing them through every function, and there is no
mutable global state.
**Alternatives:** A `newtype AppM` with derived instances (worth it once we
need custom instances, e.g. structured logging), or an effect system
(effectful, polysemy). Rejected for now as more machinery than the app needs.

### D006: SQL migrations are the schema's source of truth, run by dbmate in Docker (Phase 0, accepted)

**Decision:** The schema is hand-written SQL in `db/migrations/`, applied by
dbmate. dbmate runs from its official Docker image, so nobody installs it
locally. `db/schema.sql` (the full schema dump) is committed. persistent never
auto-migrates.
**Why:** The ledger's integrity rules (balanced entries, append-only journal)
live in SQL constraints and triggers, which ORM migrations can't express. SQL
files are also easy to review in a PR.
**Alternatives:** persistent's `migrateAll` (can't express triggers; changes
the schema implicitly), or sqitch/flyway (heavier for the same benefit).

### D007: TypeScript types generated with aeson-typescript, committed, and checked in CI (Phase 0, accepted)

**Decision:** Every API type is declared once in `Reckon.Api.Types` with
`deriveJSONAndTypeScript`. `reckon-codegen` writes
`frontend/src/api/generated.ts`, which is committed. CI regenerates it and
fails on any difference. The fetch functions in `frontend/src/api/client.ts`
are hand-written, but typed only with generated types.
**Why:** The JSON instances and the TS declarations come from the same splice
and options, so they can't drift. Committing the output lets the frontend
build without GHC.
**Alternatives:** `servant-typescript` (also generates the client functions,
but it is a small, rarely updated package). Writing a client generator on
`servant-foreign` is possible later if the hand-written wrappers become a
source of bugs. Revisit in Phase 6.

### D008: Enums go over the wire as snake_case strings (Phase 0, accepted)

**Decision:** `DatabaseReachable` is encoded as `"reachable"`. The constructor
prefix (which keeps Haskell constructor names unique) is stripped, and the
rest is snake_cased (`enumOptions` in `Reckon.Api.JsonOptions`).
**Why:** Short, readable JSON that will match the SQL enum values introduced
later (`credit_card`, `provisional`). In TypeScript it becomes a string-literal
union, so `switch` statements are exhaustiveness-checked.

### D009: `/api/health` always returns 200 and reports database status in the body (Phase 0, accepted)

**Decision:** The endpoint answers 200 with `databaseStatus: "reachable" |
"unreachable"` rather than returning 503 when Postgres is down.
**Why:** Its consumer is the UI badge, which needs to tell three states apart:
API down (request fails), API up but database down, and all good. There's no
load balancer that needs a status code. If one is added, a separate readiness
endpoint can return 503.

### D010: Postgres 17 in Docker, bound to 127.0.0.1:5433 (Phase 0, accepted)

**Why:** Docker keeps the Postgres version identical on every machine and in
CI. Port 5433 avoids clashing with a system Postgres on 5432. Binding to
127.0.0.1 means the database isn't reachable from the network, which matters
because it will hold real financial data. The test suite uses a separate
`reckon_test` database on the same server, created by `db/init/`.

### D011: Database tests fail, not skip, when the test database isn't configured (Phase 0, accepted)

**Why:** A test suite that silently skips its database tests reports green
while testing nothing. The ledger's guarantees live in the database, so those
tests are the important ones. `make test` always provides the database.

### D012: Three layers of protection against committing private data (Phase 0, accepted)

**Decision:** `.gitignore`, a pre-commit hook (installed automatically by
`make dev`), and a CI job, all backed by `scripts/check-private-data.sh`. See
[PRIVACY.md](PRIVACY.md).
**Why:** `.gitignore` alone doesn't stop `git add -f` or a CSV saved in the
wrong folder. CI alone is too late for a public repo. The hook is the layer
that actually prevents the leak.

### D013: Warnings are errors in CI only (Phase 0, accepted)

**Decision:** The cabal file turns on a broad set of warnings. CI (and
`make check`) builds with `-Werror`. Local dev builds don't.
**Why:** Unused imports mid-refactor shouldn't block `make dev`, but nothing
with warnings gets merged.

### D014: Same-origin API in development via the Vite proxy (Phase 0, accepted)

**Decision:** The frontend calls relative `/api/...` URLs, and Vite proxies
them to the backend.
**Why:** No CORS configuration, no hardcoded API host in frontend code, and
the same URLs will work in production if the backend serves the built
frontend.

### D015: Frontend scaffold kept close to Vite's defaults (Phase 0, accepted)

**Decision:** React 19, Vite 8, TypeScript 6 (strict flags from the Vite
template), oxlint (the template's linter), TanStack Query for server state.
No CSS framework yet.
**Why:** Fewer moving parts to explain, and TanStack Query handles caching,
polling, and loading and error states, which would otherwise be hand-written
`useEffect` code.

### D016: Documentation is part of every change (Phase 0, accepted)

**Context:** The owner wants to be able to hand the project to a developer at
any moment.
**Decision:** A fixed set of docs, each with one job (see the table in
CLAUDE.md). Every PR updates the ones its change affects. The PR template has
a docs checklist, and `docs/STATUS.md` is always current.

### D017: Pin `string-interpolate < 1` (Phase 0, accepted, temporary)

**Context:** aeson-typescript 0.6.4.0 uses `string-interpolate`'s `[i|...|]`
quasi-quoter. Version 1.0 of that library switched to the `ghc-hs-meta`
backend, which can't translate a `Proxy :: Proxy a` inside one of
aeson-typescript's quasi-quotes, so aeson-typescript fails to compile on GHC
9.10.
**Decision:** `constraints: string-interpolate <1` in `backend/cabal.project`.
0.3.4.0 uses `haskell-src-meta`, which handles it.
**Revisit:** when aeson-typescript or string-interpolate releases a fix. Remove
the constraint, rerun `cabal freeze`, and check that `make check` passes.

### D018: Accept aeson-typescript's `I<Name>` interface naming (Phase 0, accepted)

**Context:** For a record, aeson-typescript always emits
`export interface IHealthResponse {...}` plus
`export type HealthResponse = IHealthResponse;`. The `I` is baked into the
declaration, not controlled by a formatting option.
**Decision:** Keep it. Frontend code only ever imports the plain name
(`HealthResponse`).
**Alternatives:** Post-process the declarations to collapse the alias into a
single `interface HealthResponse`. Rejected: custom code on the codegen path
that has to handle generics correctly, for a purely cosmetic gain.

### D019: shellcheck on every script (Phase 0, accepted)

**Why:** The Makefile targets are bash, and bash fails silently in creative
ways (unquoted expansions, `cd` failures). shellcheck runs in CI and in
`make check`. It caught three real bugs in the first draft of the scripts.

### D020: Signed amounts, debits positive and credits negative (Phase 1, accepted with the owner)

**Decision:** `journal_lines.amount_cents` is one signed `BIGINT`. An entry
balances when its lines sum to zero. `naturalBalance` flips the sign for
credit-normal accounts (liability, income, equity) at display time only.
**Why:** "Balanced" is then a single `SUM(...) = 0`, and an account's balance
is a single `SUM`. It's the representation most ledger systems use internally.
**Alternatives:** Separate non-negative debit and credit columns. That's more
familiar on paper, but every sum needs a `CASE`, and a line with both columns
set (or neither) becomes a new invalid state to guard against.

### D021: The journal is append-only, enforced by triggers (Phase 1, accepted with the owner)

**Decision:** `BEFORE UPDATE OR DELETE` and `BEFORE TRUNCATE` triggers on
`journal_entries` and `journal_lines` raise an error. Mistakes are corrected
with reversing entries (`postReversal`).
**Why:** A financial record you can quietly edit can't be audited. Triggers
apply to every connection, including psql and a superuser. Permissions alone
would be silently bypassed by the superuser the app uses in development.
**Consequence:** Tests can't clean up. See D026.

### D022: Entries and their lines are posted in one Haskell transaction; balance checked by a deferred trigger (Phase 1, accepted with the owner)

**Decision:** `postEntry` inserts the entry and its lines inside the caller's
transaction. `DEFERRABLE INITIALLY DEFERRED` constraint triggers run
`check_journal_entry` at COMMIT: at least two lines, a sum of zero, and for a
reversal, an exact cancellation of the original. In Haskell, the entry's lines
are a `BalancedLines` value, which only the validating smart constructor
`mkBalancedLines` can build.
**Why deferred:** An entry is necessarily unbalanced partway through inserting
its lines. Only the finished transaction can be judged.
**Why both layers:** The Haskell type catches mistakes at compile time and
gives good error messages. The trigger is the guarantee that holds even when
the Haskell layer is bypassed (tested with raw SQL).
**Alternatives:** A `post_entry(...)` stored procedure. That keeps logic in
SQL, but it duplicates validation and is harder to test and to evolve.

### D023: Single currency (CAD), enforced with a CHECK (Phase 1, accepted)

**Decision:** `ledger_accounts.currency` exists but is constrained to `'CAD'`.
**Why:** The owner's only account is CAD. Supporting several currencies
properly means balancing per currency and recording FX gains and losses. Until
then, the constraint stops a USD account from silently breaking the
"sums to zero" rule. Lifting it is a new migration plus a per-currency check.

### D024: Lines can only be added in the transaction that created their entry (Phase 1, accepted)

**Context:** The balance trigger checks an entry when lines are inserted. Adding
a *balanced* pair of lines to an entry committed last week would pass it and
silently rewrite history, without any UPDATE.
**Decision:** `journal_entries.created_in_transaction` defaults to
`txid_current()`, and a `BEFORE INSERT` trigger on `journal_lines` rejects
lines whose entry was created in a different transaction.

### D025: Provisional vs confirmed will be a separate table, not a status column (Phase 1, accepted)

**Context:** The spec's `journal_entries.status` (provisional → confirmed)
would require an UPDATE, which D021 forbids.
**Decision:** No status column. Phase 5 will add an append-only
`entry_confirmations` table (entry id, evidence, time), and an entry is
confirmed if and only if a confirmation row exists. The history of *when* and
*why* it was confirmed comes for free.

### D026: Tests never delete; `make test` recreates the test database (Phase 1, accepted)

**Decision:** Every database test creates its own accounts with a unique
suffix (`uniqueSuffix`, from `gen_random_uuid()`) and only reads those
accounts. `scripts/test.sh` drops and re-migrates `reckon_test` before each
run (dropping a whole database isn't blocked by table triggers). CI starts
from an empty database anyway.
**Alternatives:** Wrap each test in a rolled-back transaction. Rejected
because the deferred balance trigger only fires at COMMIT, so the tests
that matter most would never exercise it.

### D027: `Cents` has no `Num` instance (Phase 1, accepted)

**Decision:** `Cents` is a `newtype` over `Int64` with `Semigroup`/`Monoid`
(addition and zero) and `negateCents`, but not `Num`.
**Why:** `Num` would allow `price * price`, which means nothing for money, and
integer literals would silently become cents (`5 :: Cents`). Every amount has
to be written `Cents 500`, which makes the unit visible.

### D028: The persistent schema is kept in step with the SQL by hand (Phase 1, accepted)

**Decision:** `Reckon.Database.Schema` describes the tables for persistent and
omits the columns the database fills in (`created_at`,
`created_in_transaction`). Enum-like columns are `TEXT` with `CHECK`
constraints, not Postgres enum types, and `AccountType` converts to and from
text itself.
**Why TEXT + CHECK:** persistent sends parameters as text, and Postgres enum
types need explicit casts. Plain text columns are also easy to read in psql.
**Risk:** The two definitions can drift. Every table is exercised through
persistent by the test suite, so a mismatch fails the tests.

### D029: Dedupe imports by (account, date, fingerprint, occurrence) (Phase 2, accepted with the owner)

**Context:** Bank CSVs have no transaction IDs. Exports overlap, and identical
transactions on the same day (two $4.50 coffees) are real and must not be
collapsed.
**Decision:** A row's *fingerprint* is its normalized descriptions (upper-case,
whitespace collapsed), cheque number and amount. Identical rows on the same
day are numbered in file order: occurrence 1, 2, and so on. The key
`(bank_account_id, transaction_date, fingerprint, occurrence)` is UNIQUE in
the database, and an import adds only keys not already stored. See
`Reckon.Import.Dedupe`.
**Why counting and not row position:** The order of *different* transactions
within a day isn't guaranteed to be stable between exports. Counting identical
rows is unaffected by order.
**Evidence it works:** A hedgehog property generates a true history full of
same-day duplicates, cuts it into overlapping exports (shuffled within days,
some with a partial last day), imports them in random order, and checks that
the result equals the true history exactly with nothing flagged. Planting a
bug (every occurrence = 1) makes it fail.
**Alternatives:** Treating `(date, description, amount)` as unique would
collapse duplicates. Hashing each row plus its position within the day would
break when the order within a day changes. A running balance column would
disambiguate perfectly, but RBC's CSV doesn't include one.

### D030: Unclear cases are flagged for review, never guessed (Phase 2, accepted with the owner)

**Decision:** Two review kinds, stored in `import_review_items`:
- `possible_duplicate`: on the same day, a stored row is absent from the newer
  export and a new row with the same amount appeared (probably renamed by the
  bank). The new row is still added. A person decides.
- `missing_from_newer_export`: a stored row is absent from a day the newer
  export fully covers.

The first and last days of an export are *edge days*. An export taken mid-day
may legitimately miss that day's later rows, so absences there are not
flagged. Nothing is ever deleted automatically.

### D031: Imported evidence is append-only, like the journal (Phase 2, accepted)

**Decision:** `raw_bank_rows`, `import_batches`, `import_batch_coverage` and
`import_review_items` reject UPDATE and DELETE (and TRUNCATE for rows), via
the same kind of trigger as the journal. Resolving a review item (Phase 6)
will add a row to a resolutions table, not edit the item.
**Consequence:** If a parser bug imports something wrongly, the fix is to
correct the parser, `make db-destroy`, and re-import the original files from
`/private`. For a personal ledger whose sources are kept, that's acceptable,
and it keeps "what the bank said" trustworthy.

### D032: A bank account is registered on its first import (Phase 2, accepted)

**Decision:** The first time an account (kind + last 4 digits) appears in an
export, reckon creates the `bank_accounts` row and the ledger account that
mirrors it: `asset:rbc-chequing-1234`, `asset:rbc-savings-1234`, or
`liability:rbc-credit-card-1234`. The import summary says "newly registered".
**Why:** There's no UI yet, and asking the owner to pre-register accounts with
SQL would be error-prone. The account kind in the export is enough to choose
the ledger account type.

### D033: Imports into one account are serialized with a row lock (Phase 2, accepted)

**Decision:** Each account's import runs `SELECT ... FOR UPDATE` on its
`bank_accounts` row before reading the stored rows it plans against. A second
concurrent import of the same account waits until the first commits. The
UNIQUE dedupe key is the backstop, since the database refuses a duplicate even
if the lock were removed.

### D034: The CSV parser is by-name, exact, and all-or-nothing (Phase 2, accepted)

**Decision:** Columns are located by header name, so reordered or extra
columns still parse. Amounts are parsed from text into integer cents with no
floating point. More than two decimals, exponents and currency symbols are
rejected. Files are read as UTF-8, falling back to Latin-1, with a leading BOM
dropped. Any bad row rejects the whole file, and every problem is listed with
its line number. USD-only rows are rejected (D023). Only the last 4 digits of
the account number survive parsing (`Last4` can only hold 4 digits).
**Unverified:** The assumed column names come from the spec and have not yet
been checked against a real RBC export (docs/STATUS.md).

### D035: `raw_bank_rows` starts smaller than the spec's suggestion (Phase 2, accepted)

**Decision:** No `status`, `is_pending`, `running_balance_cents`,
`confidence`, `source` or `position_within_day` columns yet.
- `status` (unmatched/matched/...) would need UPDATE (see D031). Matching
  will be a links table in Phase 3.
- `position_within_day` is replaced by `occurrence` (D029).
- Pending flags, running balances, confidence and source come from
  screenshots (Phase 5) and will be added with them.

### D036: Phase 2's interface is a CLI (`make import`) (Phase 2, accepted)

**Decision:** `reckon-cli import-rbc-csv FILE`, wrapped as
`make import file=private/...`, runs one import in one transaction and prints
a summary. An HTTP upload endpoint arrives with the import page in Phase 6.
**Why:** It lets the owner try real exports now, with the least new surface
area.

### D037: Tests import fixtures under a unique account number (Phase 2, accepted)

**Decision:** `ImportSpec` rewrites the fixtures' fake account number to end in
digits from `uniqueLast4` (a sequence in the test database), so each test
gets its own bank account, and its own file hash, in the shared test
database. `make check` now recreates the test database too, like `make test`.

### D038: Two defaults chosen without the owner's answer (Phase 3, accepted, owner may override)

**Context:** Two questions from the end of Phase 2 were still open when the
owner asked to keep going.
**Decision:** Went with the recommendations, flagged in the Phase 3 PR:
- A payment from chequing to a credit card reckon doesn't track goes to
  `liability:untracked-cards`, not spending. The purchases on that card were
  the spending, and counting the payment too would double-count them.
- The ledger starts from an **opening balance** taken from a statement,
  dated before the first imported transaction, posted against
  `equity:opening-balance`.

### D039: One bank row becomes exactly one journal entry (Phase 3, accepted)

**Decision:** Every posted row gets its own entry: the row's amount on its
bank's ledger account, balanced by a *counter account* (a category,
`asset:clearing`, etc.). `journal_entry_evidence` records which row an
entry came from.
**Why:** It makes the **reconciliation identity** true by construction: a
bank account's ledger balance on any date is the opening balance plus the
sum of its posted rows up to that date. The database tests check it on every
date, and a property checks it for random exports.

### D040: Transfers go through a clearing account (Phase 3, accepted, supersedes the spec's "one entry per transfer")

**Context:** A card payment leaves chequing on Feb 3 and reaches the card on
Feb 5. The spec suggested one entry for both sides.
**Decision:** Each leg is its own entry against `asset:clearing`: Feb 3
(credit chequing, debit clearing) and Feb 5 (credit clearing, debit card).
**Why:** A single entry has one date, so one of the two accounts would
disagree with its own statement between Feb 3 and Feb 5. With a clearing
account, each account matches its statement on every date, the transfer
never touches spending, and clearing's balance is exactly the money in
transit (zero once both legs have landed). This is the standard accounting
treatment ("suspense" or "clearing" account). Cancelled e-Transfers and
exact refunds use the same account and net to zero.

### D041: Pairing must be unambiguous, or it goes to review (Phase 3, accepted)

**Decision:** Two rows pair only if each is the other's *one and only*
candidate. A transfer pair means different accounts, opposite amounts, and
dates within 5 days. A cancellation or refund pair means the same account,
opposite amounts, within 45 days, with "cancel", "revers", "return", "declin"
or "refund" in one description. Cancellations are checked first. Anything
with candidates but no unambiguous pair is left unposted with a reason.
**Unverified:** The keyword lists, the card-payment guess ("PAYMENT" plus a
card name), and the sign convention for RBC credit-card exports (purchases
negative, payments positive) are assumptions until checked against real
exports.

### D042: Guesses are corrected by reversal and re-posting (Phase 3, accepted)

**Context:** If the chequing export is imported before the card's, the
payment to the card is first posted as "untracked card" (or uncategorized).
When the card's export arrives, it's really half of a transfer.
**Decision:** Rows posted on a guess (uncategorized, or untracked card) stay
eligible for pairing. When a new row pairs with one, the old entry is
**reversed** and the row re-posted against `asset:clearing`. The reversal is
dated like the entry it reverses, so the account's balance on every date is
unchanged. Nothing is edited (D021).

### D043: Reconciliation explains the gap, not just its size (Phase 3, accepted)

**Decision:** `reckon-cli checkpoint` / `make reconcile` compare the ledger
with a statement balance. When they differ, the report looks for a cause:
unposted rows whose sum is the gap, a single row equal to it, a missing
opening balance, a possible duplicate equal to it, and days no export
includes (coverage is inferred from each export's first and last
transaction dates, since RBC's CSV doesn't state its range). When the
balance matches, only "reconciled" is shown.

### D044: Categorization rules are "description contains → account" for now (Phase 3, accepted)

**Decision:** A `categorization_rules` table with upper-cased text,
priority and account. The first match wins. Rules are configuration and may
be edited, and they apply to rows posted *after* they're added. Phase 7
replaces this with the rule language (and "preview against past
transactions").

### D045: Pending transactions and debit holds move to Phase 5 (Phase 3, accepted, scope change)

**Context:** Phase 3 in the spec includes pending→posted handling and
pending debit holds.
**Decision:** Deferred to Phase 5. CSV exports contain only posted
transactions, so pending rows only exist once screenshots are imported. The
mechanism needed (reverse the provisional entry, post the final one) is the
same reversal-and-re-post used by D042.

### D046: `post-row` settles review items until the Phase 6 review queue (Phase 3, accepted)

**Decision:** `scripts/reckon.sh post-row ROW_ID ACCOUNT` posts one
unposted row against an account of your choice (e.g. both legs of an
ambiguous transfer to `asset:clearing`). `make post` lists the row ids it
left for review.

### D047: Posting tests isolate themselves by year and tag (Phase 3, accepted)

**Context:** `postPendingRows` looks at every unposted row in the database,
and rules are global. Tests share one database.
**Decision:** Each posting test (a `Scenario`) rewrites the fixture into
its own account numbers, **its own year** (3000 + n), so pairing windows
can't overlap between tests, and its own description tag, so its rules
match only its rows. Assertions only look at the scenario's own rows.

### D048: e-Transfer counterparty names are read in Phase 4 (Phase 3, accepted, scope change)

**Context:** The Phase 3 spec says to extract the counterparty's name from
e-Transfer descriptions.
**Decision:** Moved to Phase 4. In Phase 3, e-Transfers are ordinary rows
(categorized by rules, and cancelled ones paired). The name only matters
once repayments are matched to a friend's receivable, which is Phase 4, and
the real description format is still unverified.

### D049: A split is one entry with several lines on the far side (Phase 4, accepted)

**Context:** A $120 dinner paid from chequing should count as $30 of spending
and $90 owed to me by three friends.
**Decision:** The row's entry (still one entry, still linked to its one bank
row, D039) has a line on the bank account for −$120, and on the other side
one line per participant: my share in a category, and each friend's share
in `receivable:<name>`. **My share is whatever the friends' shares leave
over**, so the parts add up to the payment exactly and the entry can't be
unbalanced. `equal` splits give any odd cents to me first (the person who
paid absorbs rounding), then to the friends in the order given. A friend's
share must be positive, no one may be listed twice, and only a payment *out*
can be split. These rules are a pure smart constructor (`Reckon.Posting.Split`)
with property tests.
**Alternatives:** Several entries per row (one per friend): breaks "one row,
one entry" and the reconciliation identity. A `splits` table beside the
entry: a second copy of the amounts that could disagree with the lines.

### D050: Repayments are suggested, never applied automatically (Phase 4, accepted, owner may override)

**Context:** When a friend e-Transfers me back, it should reduce what they
owe. The owner hadn't answered whether to apply that automatically.
**Decision:** Taken as the recommended default: a `people` table (name,
`match_text`, receivable account). Money *coming in* to a chequing or
savings account whose description contains someone's `match_text` is left
for review as `PossibleRepayment`, with the exact `post-row` command to
apply it. It is not posted as income and not applied on a guess. A
categorization rule the owner wrote still wins.
**Why:** A wrong automatic match is silent: Alex sends $30 for rent, it
reduces his dinner debt, and both numbers are wrong with no warning. A
suggestion costs one command. If the owner prefers automatic matching, it's
a small change in `Classify`: post a unique match to the person's receivable.
**Unverified:** How RBC writes the sender's name in an e-Transfer
description. `match_text` is whatever the owner says it is, so this works
with any format, but it needs a real description to choose a good one.

### D051: Re-posting by reversal, but never one leg of a pair (Phase 4, accepted)

**Decision:** `split-row` and the new `recategorize` command replace a row's
entry the way D042 does: reverse the old entry **dated like the original**,
post the new one, nothing edited. This also settles the known issue that
rules don't re-categorize the past (one row at a time, on request).
A row whose entry touches `asset:clearing` (a transfer leg, a cancelled
pair, or a pair settled by hand) is **refused**: moving one leg alone would
leave the clearing account out of balance. Nothing is written when a request
is refused or invalid.

### D052: "Spending" is the expense accounts, and nothing else (Phase 4, accepted)

**Decision:** `spending FROM TO` sums only `expense` accounts. Friends'
shares sit in receivables (assets), transfers and cancellations in the
clearing account, card payments in `liability:untracked-cards`, so none of
them can inflate spending, and reversals cancel out. "Reported spending
reflects only my share" therefore falls out of the account structure and
needs no special filter. (The Phase 6 UI adds months and charts.)

### D053: Recognize repayments by stored text, not by parsing the description (Phase 4, accepted, resolves D048)

**Context:** D048 moved "extract the e-Transfer counterparty's name" to
Phase 4.
**Decision:** Don't parse. Each person has a `match_text` the owner chooses,
and a repayment is a description containing it. Parsing would hard-code an
RBC description format that hasn't been verified against a real export;
matching a user-supplied string works with whatever the format turns out
to be, and ambiguity (two people matching) is shown rather than guessed.

### D054: A raw-HTTP Claude client, with the model chosen by an environment variable (Phase 5, accepted, owner may override the model)

**Context:** Phase 5 sends screenshots to the Anthropic Messages API from the
backend. There is no official Haskell SDK.
**Decision:** `Reckon.Anthropic` is a small client over `http-client`: one
request shape (an image plus instructions, the reply constrained to a JSON
Schema with `output_config.format`) and one response shape. The request
builder and response parser are pure and tested; only `anthropicExtractor`
touches the network. Tests never reach the real API: they use a fake
`Extractor` (a function from an image to the model's reply text), recorded
fake replies in `fixtures/screenshots`, and an in-process stub server that
checks headers, retries and error handling.
- The model ID comes from `ANTHROPIC_MODEL` and **defaults to
  `claude-opus-5-5`**. That default was chosen without the owner's input:
  it's the most capable current model, but also the most expensive way to read
  a screenshot. The way to decide is to run `eval-screenshots` on labelled
  screenshots with a cheaper model and compare (D060).
- The request sets nothing the newer models reject: no sampling parameters,
  no forced `tool_choice`, no thinking budget. Structured output replaces a
  forced tool call.
- **The key** is read from `ANTHROPIC_API_KEY`, sent only as a request
  header, and can't be printed: `ApiKey` has a hand-written `Show`, the
  request's `x-api-key` header is marked redacted, and errors are built from
  the response (or an exception's *content*, never the request). A test
  asserts the key appears in no error or `show` output.
- 429 and 5xx responses are retried twice with a growing pause.

### D055: The model transcribes; Haskell interprets and refuses (Phase 5, accepted)

**Decision:** The model is asked only to copy what's on screen: the date as
displayed ("Feb 14", "Today"), the amount as displayed ("-$12.34"), a
direction (debit, credit, unknown), pending or posted, a running balance if
shown, whether it was unsure, and whether the row is cut off. Everything
that needs judgement or arithmetic happens in `Reckon.Screenshot.Extraction`:
- **The year is inferred in code**: the most recent such date that isn't
  after the day the screenshot was taken (`--taken`, default today). "Today"
  and "Yesterday" are read against the same day.
- Amounts become exact cents by the same parser as the CSV. The sign comes
  from the direction; a minus sign contradicting "credit" is an error.
- **Strict, all-or-nothing:** an extra or missing field, an unknown
  direction, an unreadable date or amount, a zero amount, or an empty
  description rejects the *whole* response and lists every problem with its
  row number, like a bad CSV. Nothing is stored, and the image can be
  retried because it was never recorded.
- **Account numbers can't get in:** a run of nine or more digits in a
  description or the account label is rejected. The model is told never to
  return one; this checks that it didn't. (A heuristic, and unverified
  against real descriptions.)
- Rows cut off at a screen edge are dropped (they appear whole in the
  neighbouring screenshot). Rows the model marked uncertain are stored but
  never posted.
**Why:** A model that "helpfully" fills in a year, or does arithmetic, can be
confidently wrong. Code that refuses is easier to trust than a prompt that
asks nicely.

### D056: Joining a scroll by its overlap, and saying when it's ambiguous (Phase 5, accepted)

**Decision:** Screenshots of one scroll are given to `import-screenshots`
top of the list first. For each next screenshot, `alignScreenshots` finds
the longest run of rows at the end of what's been joined that equals the
start of the next one, and joins there. Rows are "the same" when their date,
words, amount, section and running balance (if shown) match.
- Two coffees in a row aren't duplicates to drop: they only overlap if the
  next screenshot's start matches the previous one's end.
- When more than one overlap length fits (identical rows with no balance to
  tell them apart), the **longest** is used, since it invents the fewest
  rows, and a warning says so.
- No shared rows at all: a warning that transactions between them may be
  missing. Screenshots given in the wrong order: noticed, joined the right way
  round, with a warning.
- Rows already stored from an earlier import are skipped by the same
  identity scheme as CSVs (account, date, fingerprint, occurrence), so
  overlap between *separate* imports is handled too.

### D057: Matching provisional rows to the bank's, unambiguously (Phase 5, accepted)

**Decision:** `planMatches` decides which provisional row is which later row
(a CSV row, or a later screenshot's posted row). Same discipline as transfer
pairing (D041): a match needs each to be the other's *only* candidate.
- Same amount: dates within 3 days, and a meaningful word in common ("Interac
  purchase - COFFEE CO" in an export is "Coffee Co" in the app; generic
  words like PURCHASE don't count).
- A pending hold that posted for a different amount (a $100.00 gas hold
  posting at $43.20): only for pending rows, the same direction of money,
  within 7 days after the hold, with a word in common.
- Identical rows (two coffees on a day) are interchangeable, so they're
  matched as a group, in order. A screenshot with three where the bank has
  two leaves the third unmatched.
**Unverified:** the window sizes and what counts as "a word in common" are
assumptions until checked against real exports and screenshots.

### D058: Screenshots are their own evidence, posted provisionally and resolved by reversal (Phase 5, accepted, supersedes the spec's "raw_bank_rows with source = screenshot")

**Context:** The spec put screenshot rows in `raw_bank_rows` with a source and
a confidence. But those rows are append-only and their identity is tied to CSV
fingerprints, and a screenshot row has different life: it's provisional, and
gets confirmed, replaced or released.
**Decision:** Four tables (migration `20260926090000_create_screenshots.sql`):
`screenshot_uploads` (hash, model, the validated reply), `screenshot_rows`,
`screenshot_entry_evidence` (which entry was posted from which row) and
`provisional_resolutions`. A row read with confidence is posted as an
entry ("(provisional) ...") so the ledger shows it. It stays *open* until:
- `confirmed_by_csv`: a CSV row for the same transaction is posted (`make
  post`): the provisional entry is **reversed, dated like the original**, and
  the CSV row is posted the normal way;
- `already_in_csv`: the CSV row was already there when the screenshot was
  read, so nothing is posted;
- `superseded_by_screenshot`: a later screenshot shows a pending hold posted;
- `released`: the owner says a hold never posted (`release-provisional`).
A database CHECK ties each kind to the columns it needs. A CSV row can be
claimed by at most one screenshot row (UNIQUE). Nothing is edited or deleted.

### D059: The reconciliation identity now includes open provisional rows (Phase 5, accepted)

**Decision:** For every bank account and date: ledger balance = opening
balance + posted CSV rows + **open provisional rows**. When a statement
disagrees with the ledger by exactly the open provisional rows, the report
says so (`ProvisionalRowsExplainGap`): the statement doesn't have them yet,
and the bank's CSV will confirm them. Once confirmed, the identity is the
Phase 3 one again.

### D060: Phase 5 scope as built, and what is unverified (Phase 5, accepted, scope change)

**Decision:**
- **CLI first.** `import-screenshots LAST4 [--taken DATE] FILE...` reads
  images from disk. The HTTP upload endpoint and the upload page are Phase 6
  with the rest of the frontend. The account is named by its last 4 digits,
  not read from the screen (the model never returns account numbers), and
  must already be registered by a CSV import.
- **Pending transactions and holds** (moved here from Phase 3, D045) work
  as D057/D058 describe.
- **The evaluation script** is `reckon-cli eval-screenshots DIR`: pairs of
  image and hand-written label in `private/eval`, scored for rows found,
  missed and invented, and field accuracy. Never committed; the scoring is
  ordinary tested code.
- **Unverified:** nothing in this phase has talked to the real API or seen a
  real RBC screenshot. The prompt, the schema, the heuristics (nine-digit
  guard, windows, "a word in common") and the default model are all
  untested against reality. `eval-screenshots` on a handful of real
  screenshots is the first thing to run.

### D061: Keeping a login-less API private on one machine (Phase 6, accepted)

**Context:** From Phase 6 the server exposes real financial data (and can
change the ledger) over HTTP. There is no login: reckon is a single-user tool
on its owner's machine. "No login" is only safe if nothing but the owner's
browser can reach the API, and a web page you merely *visit* can try to.

**Decision:** three independent layers, all in `Reckon.Security` /
`Reckon.Config`:
1. **Listen on loopback only.** `RECKON_HOST` defaults to `127.0.0.1`. Other
   machines on the network can't connect at all.
2. **Host-header allowlist** (`hostGuard`). A request whose `Host` isn't in
   `RECKON_ALLOWED_HOSTS` (default `localhost`, `127.0.0.1`, `[::1]`) gets 403.
   This is the defence against *DNS rebinding*: a hostile page whose domain
   first resolves to its own server and then to 127.0.0.1 would otherwise have
   the browser treat our API as same-origin and let it read everything. Its
   requests carry `Host: evil.example.com`, which we refuse.
3. **Writes must be `application/json`** (`jsonOnlyWrites`). A cross-site form
   or `text/plain` POST is a "simple" request that browsers send without
   asking permission; a JSON one needs a CORS preflight, which we never
   answer. Servant already returns 415 for routes that declare a JSON body;
   the middleware also covers a future write route that declares none, and
   has its own test for that reason (a mutation check showed Servant's check
   was hiding the middleware's absence).

The Vite dev proxy keeps `Host: localhost:5173`, so development needs no
configuration; opening the dev server by LAN address is refused until the
name is added to `RECKON_ALLOWED_HOSTS` (and `RECKON_HOST` is widened).

**Alternatives considered:** a shared-secret token header (stronger against a
malicious local process, but then the frontend must hold the secret, which
needs a login flow: too much for a one-user local tool, and a local process
can already read the database); a CORS allowlist only (doesn't stop rebinding
reads, since a rebound page is same-origin); a Unix socket (browsers can't
speak to one without a proxy); no protection ("it's localhost"), which is
exactly the mistake DNS rebinding exploits.

**Not defended:** another program running as you on this machine. It could
read `.env` and the database directly anyway.

### D062: The HTTP API's shape: views, actions, refusals, uploads (Phase 6, accepted)

**Decision:**
- **Reads** are `GET` endpoints that answer one screen's question each
  (`/api/accounts`, `/api/accounts/:last4/transactions`, `/api/spending`,
  `/api/receivables`, `/api/review`, `/api/ledger-accounts`). Their queries
  live in `Reckon.Views` and return the API's own types, so the frontend never
  joins or re-derives anything; money crosses the wire as integer cents.
- **Actions** are `POST`s that run exactly the code the CLI runs and answer
  `ActionResult {message, details}`, the same sentences the CLI prints
  (`Reckon.Messages` holds the wording, shared by both). So the CLI and the UI
  can't drift into describing a refusal differently.
- **Refusals** are `{ "problem": "..." }` with a status that says whose fault
  it was: 400 malformed input (bad date, bad base64), 404 no such row/account,
  422 the ledger refused (unbalanced, ambiguous, a transfer leg on its own...),
  502 the model's reply couldn't be used, 503 screenshot reading not
  configured. The frontend shows `problem` verbatim.
- **Uploads are JSON with base64 content**, not multipart. Files are small
  (a CSV, a few screenshots), base64 costs a third more bytes on the wire,
  and in exchange there is one body format everywhere, no multipart
  dependency, and `jsonOnlyWrites` (D061) can refuse everything else.
  Multipart forms are exactly what a cross-site `<form>` can send.
- **`asOf`** (optional date) on balance endpoints. Defaults to today; tests
  pass the end of their scenario's year so they are independent of the clock.
- **Screenshot reading is decided once at startup:** with
  `ANTHROPIC_API_KEY` set the server holds an `Extractor`
  (`ReadingAvailable`), otherwise `ReadingUnavailable` and the endpoint
  answers 503 with how to fix it. The key never leaves the process.

**Alternatives considered:** one generic `/api/command` endpoint (loses typed
requests and the generated TypeScript); exposing the ledger tables and letting
the frontend assemble screens (moves reconciliation rules into JavaScript,
where they'd be wrong); multipart uploads.

### D063: Transactions are what the ledger says *now* (Phase 6, accepted)

**Decision:** the transactions list shows the entries on a bank account as
the bank would show them, newest first, **omitting reversed entries and the
reversals themselves**. A corrected posting appears once, as the corrected
entry. The journal still holds the whole history (append-only); the page is
a current view, not an audit log. Amounts are the account's raw signed line:
money in is positive and money out negative for chequing, savings and cards
alike, which keeps a column scannable without per-kind rules. (Account
*balances* are the opposite convention on purpose: they use the sign the
bank prints, e.g. money owed on a card, matching the statement they are
reconciled against.)

Only a posted **CSV** row offers "recategorize" and "split": a screenshot row
is provisional and settles itself when its CSV row arrives (D058).

### D064: The frontend's structure (Phase 6, accepted)

**Decision:**
- **No UI framework and no router library.** Six pages, one stylesheet using
  CSS variables (light and dark follow the system), a ~30-line hash router
  (`lib/route.ts`) whose `Route` is a union type, so a page can't be forgotten
  (`satisfies never` in the switch). The fragment keeps the server out of
  routing and survives a refresh.
- **TanStack Query for server state; every successful action invalidates all
  queries** (`useAction`). Any action can change any page (a post moves a
  balance, a review item and a checkpoint at once), and with six small pages
  refetching everything is simpler than, and never staler than, hand-picking
  keys.
- **Types come only from `generated.ts`**; `strict` TypeScript is now on.
- **Money is integer cents end to end.** `formatCents` and
  `parseAmountToCents` are the only conversions, tested exhaustively over a
  range and for the inputs that would silently lose cents ("1.234" is
  refused, not rounded). The one division, a spending bar's width, is
  isolated in `barPercent` and is never displayed or summed.
- **Tests:** Vitest for pure logic, and Testing Library with a fake `fetch`
  (`src/testing.tsx`) for the pages, which assert on what the user sees and on
  the exact JSON sent. `npm test` runs in CI and `make check`.

**Alternatives considered:** React Router (a dependency for six pages);
Redux/Zustand (server state is TanStack Query's job and there is little
client state); a component library (the point of the project is the
ledger, and the pages are forms and tables); MSW for network mocking (a
dependency where a 25-line fake `fetch` is clearer).

### D065: Phase 6 scope as built, and what is deferred (Phase 6, accepted, scope change)

**Built:** accounts (balances, unposted counts, latest reconciliation with its
explanation, record a statement or opening balance, post imported rows),
transactions (account tabs, date and text filters, recategorize, split with
friends), spending by month with bars, receivables and add a friend, a review
queue (rows needing a decision, settle or apply a repayment to a friend,
release a provisional row, import warnings, add a rule), and import of CSVs
and screenshots.

**Deferred (known gaps):**
- **Charts beyond bars.** A charting library isn't justified yet.
- **Paging past the newest 200 transactions;** narrow the dates instead.
- **Listing or editing people and rules.** You can add them; removing or
  changing one is a CLI/SQL job for now. The split form takes names as
  text, because there is no endpoint that lists people.
- **Exact-amount splits in the UI.** The API supports them (`shares`); the
  form offers equal splits only.
- **Untested against a real browser session with real data.** Verified with
  fixture data and headless Chromium screenshots only.
- **Authentication.** By design (D061).

### D066: Request logging never includes request bodies (Phase 6, accepted)

**Context:** the server used `logStdoutDev`, whose detailed format prints any
request body under 2 KB. Phase 6 added endpoints whose bodies are financial
data (a CSV upload, a balance), so a small file would have been printed to the
terminal and into whatever captures it.

**Decision:** `logStdout` (Apache format: client, method, path with query,
status, user agent). No bodies, no headers. Verified by sending a body with a
marker string and finding it absent from the log. Search text (`?q=`) is in
the path, so it can appear in the log on the owner's own machine; it never
leaves it.

**Alternative:** keep the dev logger in development only. Rejected: "only in
development" is also where the real data is, since there is no other
environment yet.

### D067: A small rule language, parsed with megaparsec (Phase 7, accepted)

**Context:** the original rules were "description contains TEXT, then this
account" (D044). Real categorization needs "...and it's over $50", "...but
only on the card", and "split this with friends", and a person writing a rule
needs to be told exactly what is wrong with it.

**Decision:** a rule is one line of text, read by a parser:

```
when description contains "TIM HORTONS" then categorize expense:coffee
when description starts with "UBER" and amount < -50.00 then categorize expense:transport
when description contains "DINNER" and account is credit card then split expense:food equally with alex, sam
```

Conditions (joined by `and`): `description contains | starts with | ends with
"TEXT"`, `amount < | <= | > | >= | = | != N` (as the bank shows it: money out
is negative), `account is chequing | savings | credit card`. One action:
`categorize ACCOUNT`, or `split ACCOUNT equally with NAME, NAME`. Keywords
are case-insensitive and whitespace (including line breaks) doesn't matter.

- **`Reckon.Rules.Language`** is pure: the AST (`Rule`, `Condition`,
  `Action`), `parseRule`, `renderRule`, and `RuleProblem {line, column,
  message}`. The parser is megaparsec (already in the dependency tree via
  other packages, so no new package to compile). Errors name the line and
  column and what was expected; mistakes the grammar can't express as syntax
  (a third decimal on an amount, an account with no known type, a split into a
  non-expense account, the same friend twice) are reported *at the offending
  token* with `parseError`, not at wherever parsing happened to stop.
- **`Reckon.Rules.Eval`** is pure: does a rule hold for a row (`Candidate`)?
- **`parseRule (renderRule r) == Right r`** is a property test, so the text a
  person sees after saving is always something the system reads back.
- **Amounts are exact.** `12.5` is 1250 cents, `1.234` is an error (not
  rounded), and a rendered amount is never a float.
- **A split rule is equal shares only**, with the odd cents going to me
  first (D049). It applies to money going out only, and only when every friend
  would owe at least a cent; for anything else (money in, an unknown friend, a
  2-cent payment shared three ways) the rule is *passed over*, so the next rule
  or the guess decides, rather than half-applying.

**Deliberately absent:** regular expressions (matching text is what people
actually write, and a regex is a second language to get wrong), `or` and
parentheses (write two rules; the first match wins), dates, and rules that
reference other rules. Each could be added to the grammar without changing the
stored format.

**Alternatives considered:** a JSON or form-built rule (fine for storage,
terrible for typing and for explaining an error); regular expressions; a
`parsec`/hand-rolled parser (megaparsec's error messages and `reachOffset`
for line/column are exactly what the UI needs); embedding a scripting language
(a security and testing burden for a handful of conditions).

### D068: Rules are stored as text, in canonical form (Phase 7, accepted)

**Decision:** migration `20260927090000` replaces `categorization_rules` with
`posting_rules (rule_text, priority)`, and converts every existing rule to the
new text in SQL (quotes and backslashes escaped the way the language reads
them; tested on a rule containing both). The database holds the text and
nothing else, so there is no structured copy to drift out of step with it:
everything that uses rules parses the stored text.

- **Canonical form.** `addRule` stores `renderRule (parseRule text)`.
  Description text is kept upper-case with single spaces (as descriptions are
  compared), account and friend names lower-case, amounts with two decimals. So
  `WHEN description CONTAINS "tim  hortons" ...` and the same rule written
  tidily are one rule, and the `UNIQUE (rule_text)` constraint catches a
  duplicate that differs only in spacing or case (a bug the first test run found:
  literals weren't normalized and the two copies were both saved).
- **Validated before it is saved** (`checkRule`): it must parse, and every
  friend it names must have been added (`add-person`), reported at their name.
  The category account is created if needed.
- **Never stops posting.** `loadRules` leaves out a stored rule that no longer
  parses or whose account is gone, instead of failing every `post`; the Rules
  page shows it with its problem.
- **Rules are configuration, not evidence**, so they can be deleted (rows
  already posted keep their account). The down migration recreates the old
  table empty: rules written in the new language can't all be expressed in the
  old format, so they are lost going down.
- The original `add-rule TEXT ACCOUNT [PRIORITY]` still works (it builds the
  equivalent rule), and the lower-casing of account names is the one change.

### D069: Rules apply to the past only when asked, one rule at a time (Phase 7, accepted)

**Context:** "Rules don't re-categorize the past" (D044) meant adding a rule
did nothing for the hundreds of rows already posted as `expense:uncategorized`.

**Decision:** `Reckon.Rules.History` adds two operations and the rule is never
silently applied:
- **`previewRule`** (pure, over `loadHistory`'s rows) says which existing rows
  the rule matches and what would happen to each: *moves from X*, *already
  there*, *applies when posted* (not posted yet), or *can't change* (part of a
  transfer, a cancelled pair or a split; or a split of money coming in).
  Nothing is written. The UI and `check-rule` call it as you type.
- **`applyRule`** moves exactly the rows the preview says would move, each by
  the existing `recategorizeRow` / `splitRow` (reverse dated like the original,
  then post: no balance on any date changes, D051). A row the ledger refuses
  to change is reported and the rest carry on.
- **One rule at a time, ignoring priorities.** The preview answers "what would
  *this rule* do to the rows it matches", which is what the person writing it
  wants to see. A row that a different rule or a manual recategorization put
  elsewhere is shown moving *from* there, so nothing is hidden, and the person
  decides. Applying the whole rule set in priority order, retroactively, is a
  different (and more dangerous) feature.

**Alternatives considered:** applying a new rule to history automatically when
it's saved (a wrong rule would silently rewrite the past; reversible, but
noisy); previewing against the full rule set (surprising: a rule's preview would
change when an unrelated rule is added).
