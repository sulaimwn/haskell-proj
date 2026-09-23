# Status

**The handoff doc.** If you're picking this project up, read this first,
then [CLAUDE.md](../CLAUDE.md). Updated in every PR.

_Last updated: 2026-09-23, end of Phase 2._

## Where we are

**Phase 2 (RBC CSV import) is complete** and waiting for the owner's review.
Phase 3 (turning evidence into journal entries) starts after that.

| Phase | Status |
|---|---|
| 0: Environment and skeleton | ✅ merged ([PR #1](https://github.com/sulaimwn/haskell-proj/pull/1)) |
| 1: Ledger core | ✅ merged ([PR #2](https://github.com/sulaimwn/haskell-proj/pull/2)) |
| 2: RBC CSV import | ✅ done, in review |
| 3: Evidence → entries, transfers, reconciliation | ⏭ next |
| 4–8 | not started |

## What works today

**Importing (Phase 2):** `make import file=private/export.csv`

- Parses RBC's CSV export by column name, reads amounts as exact cents, and
  rejects the whole file (listing every bad line) if any row is invalid.
- Keeps **only the last 4 digits** of account numbers, enforced by a type, a
  CHECK constraint, and a test that scans everything stored.
- Registers each bank account on first sight, with a mirroring ledger account
  (`asset:rbc-chequing-1234`).
- **Dedupe** (approved design, DECISIONS D029/D030): re-importing the same
  file is a no-op; overlapping exports add only new rows; identical same-day
  transactions are kept; renamed rows and rows missing from a newer export
  are flagged in `import_review_items`, never guessed.
- Imported evidence is append-only, and each import is one transaction.
- Tested with 64 examples in total, including a property that reconstructs a
  random true history exactly from random overlapping, shuffled, partial
  exports.

**Ledger (Phase 1):** balanced, append-only journal enforced by the database;
post entries and reversals; balances as of a date.

**Skeleton (Phase 0):** `make dev`, `/api/health` with a live badge,
TypeScript types generated from Haskell, the privacy guard, CI.

Imports don't create journal entries yet. `raw_bank_rows` is evidence
waiting for Phase 3.

## Unverified: the real RBC format

The parser uses the column layout from the spec (Account Type, Account
Number, Transaction Date, Cheque Number, Description 1, Description 2, CAD$,
USD$) and M/D/YYYY dates. **It hasn't been run on a real export yet.** When
the owner runs `make import` on a real file:

- If it imports: check the summary looks right (dates, row counts).
- If it's rejected: the error lists line numbers and reasons. Share those
  (not the file) so the parser can be corrected.

## What's next: Phase 3 (evidence → entries)

From [SPEC.md](SPEC.md#phase-3-turning-evidence-into-entries):
turning `raw_bank_rows` into journal entries (with a links table rather than
a status column), rule-based categorization, transfer pairing, pending vs
posted, statement checkpoints and the reconciliation report, plus the
chequing flows agreed in Phase 0: e-Transfers (including cancelled ones),
bill payments, and pending debit holds.

Design questions to bring to the owner at the start of Phase 3:
- Payments to credit cards reckon doesn't track: `liability:untracked-cards`
  (as the spec proposes) or treat them as spending?
- The opening balance: an `equity:opening-balance` entry dated before the
  first import, entered by hand from a statement?

## Open questions for the owner

1. Production deployment target for the Phase 8 demo (Fly.io, Render, a VPS,
   or local-only). Doesn't block anything until Phase 8.

## Resolved

- **Phase 2 dedupe design** (2026-09-23): approved as proposed (D029, D030).
- **Phase 1 design** (2026-09-23): D020, D021, D022.
- **Phase 3 scope with only a chequing account** (2026-09-22): keep the card
  and transfer features (fake fixtures), **and** add e-Transfers, bill
  payments, and pending debit holds.

## Known issues and tech debt

- **Review items repeat.** Until Phase 6 adds a way to resolve them, a later
  overlapping import can flag the same situation again (e.g. the old version
  of a renamed row is "missing" from every newer export).
- The parser's column layout is unverified against a real export (above).
- `string-interpolate` is pinned to `<1` because aeson-typescript doesn't
  compile against 1.x on GHC 9.10 (D017).
- aeson-typescript names record interfaces `I<Name>` with a `<Name>` alias
  (D018). Cosmetic.
- persistent entities are kept in step with the SQL by hand (D028). Every
  table is exercised through persistent in tests.
- `check_journal_entry` runs once per inserted row. Negligible at this scale.
- The frontend has no unit tests yet. Vitest arrives with real display logic
  (Phase 6).
