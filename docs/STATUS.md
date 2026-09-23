# Status

**The handoff doc.** If you're picking this project up, read this first,
then [CLAUDE.md](../CLAUDE.md). Updated in every PR.

_Last updated: 2026-09-23, end of Phase 1._

## Where we are

**Phase 1 (ledger core) is complete** and waiting for the owner's review.
Phase 2 (RBC CSV import) starts after that.

| Phase | Status |
|---|---|
| 0: Environment and skeleton | ✅ merged ([PR #1](https://github.com/sulaimwn/haskell-proj/pull/1)) |
| 1: Ledger core | ✅ done, in review |
| 2: RBC CSV import | ⏭ next |
| 3–8 | not started |

## What works today

**Ledger core (Phase 1), backend only, with no API endpoints or UI yet:**

- Tables `ledger_accounts`, `journal_entries`, `journal_lines`
  (`db/migrations/20260922210000_create_ledger.sql`).
- The database itself enforces that every entry has at least 2 lines summing
  to zero (checked at COMMIT); that the journal is append-only (UPDATE,
  DELETE and TRUNCATE rejected); that a committed entry can never gain lines;
  and that a reversal exactly cancels its original, at most once.
- Haskell: `Cents` (exact money, no `Num`), `AccountType` with display signs,
  `BalancedLines` (can only be built balanced), and `createLedgerAccount`,
  `postEntry`, `postReversal`, `accountBalanceAsOf` (esqueleto).
- Tests (33 examples, all passing): pure hedgehog properties for the entry
  rules; database tests for balances, reversals, and each database rule
  checked with raw SQL; and a model-based hedgehog property that runs 100
  random scenarios of entries and reversals against the real database. A
  deliberately planted bug was caught by the property.

**From Phase 0:** `make dev` (Postgres, migrations, API on :8080, frontend on
:5173), `/api/health` with a live badge, TypeScript types generated from
Haskell, the privacy guard, CI, and the docs.

## Design decisions made in Phase 1

With the owner: signed amounts, debit + and credit − (D020);
append-only via triggers (D021); posting in one Haskell transaction with a
deferred balance trigger (D022).

Also: CAD-only CHECK (D023), lines only in their entry's transaction (D024),
"provisional/confirmed" deferred to a separate append-only confirmations
table in Phase 5, since a status column would need UPDATE (D025), test
isolation by unique names plus database recreation (D026), `Cents` without
`Num` (D027), persistent schema kept in step with the SQL by hand, TEXT +
CHECK instead of Postgres enums (D028).

## What's next: Phase 2 (RBC CSV import)

From [SPEC.md](SPEC.md#phase-2-rbc-csv-import):

1. **Needs the owner:** a real RBC chequing CSV export, kept in `/private`
   and never committed, to verify the assumed columns (Account Type, Account
   Number, Transaction Date, Cheque Number, Description 1, Description 2,
   CAD$, USD$) and see real descriptions for e-Transfers, bill payments and
   holds. Only the header row and the *shape* of a few rows are needed. The
   values can be redacted.
2. Migrations for `bank_accounts`, `import_batches`, `raw_bank_rows`.
3. The dedupe design for overlapping exports and same-day identical
   transactions, **explained to the owner before implementing** (the spec
   requires this).
4. Fake RBC-format fixtures covering the edge cases.

## Open questions for the owner

1. Production deployment target for the Phase 8 demo (Fly.io, Render, a VPS,
   or local-only). This doesn't block anything until Phase 8.

## Resolved

- **Phase 3 scope with only a chequing account** (2026-09-22): keep the card
  and transfer features (fake fixtures), **and** add Interac e-Transfers
  (including cancelled ones), bill payments, and pending debit holds.
- **Phase 1 design** (2026-09-23): D020, D021, D022, as above.

## Known issues and tech debt

- `string-interpolate` is pinned to `<1` in `backend/cabal.project` because
  aeson-typescript doesn't compile against 1.x on GHC 9.10 (D017).
- aeson-typescript names record interfaces `I<Name>` with a `<Name>` alias
  (D018). Cosmetic.
- The persistent entity definitions are kept in step with the SQL by hand
  (D028). The test suite exercises every table through persistent, so drift
  fails the tests, but there is no automatic schema diff.
- `check_journal_entry` runs once per inserted row (a deferred row trigger),
  so an entry with *n* lines is checked *n* + 1 times at COMMIT. That's
  negligible at personal-finance scale. A statement-level variant is possible
  if it ever matters.
- The frontend has no unit tests yet. Vitest arrives with real display logic
  (Phase 6).
