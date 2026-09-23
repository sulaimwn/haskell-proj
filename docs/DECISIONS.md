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
