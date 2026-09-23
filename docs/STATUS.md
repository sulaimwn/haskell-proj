# Status

**The handoff doc.** If you're picking this project up, read this first,
then [CLAUDE.md](../CLAUDE.md). Updated in every PR.

_Last updated: 2026-09-23, end of Phase 3._

## Where we are

**Phase 3 (evidence → entries, transfers, reconciliation) is complete** and
waiting for the owner's review. Phase 4 (shared expenses and receivables)
starts after that.

| Phase | Status |
|---|---|
| 0: Environment and skeleton | ✅ merged ([PR #1](https://github.com/sulaimwn/haskell-proj/pull/1)) |
| 1: Ledger core | ✅ merged ([PR #2](https://github.com/sulaimwn/haskell-proj/pull/2)) |
| 2: RBC CSV import | ✅ merged ([PR #3](https://github.com/sulaimwn/haskell-proj/pull/3)) |
| 3: Evidence → entries, transfers, reconciliation | ✅ done, in review |
| 4: Shared expenses and receivables | ⏭ next |
| 5–8 | not started |

## What works today

The full loop, from a bank export to a reconciled ledger, on the command
line. Step by step: [DEVELOPMENT.md](DEVELOPMENT.md#from-import-to-a-reconciled-ledger).

```bash
make import file=private/export.csv                     # evidence
scripts/reckon.sh add-rule PAYROLL income:job           # optional rules
make post                                               # evidence → journal entries
scripts/reckon.sh post-row 7 asset:clearing             # settle what it wouldn't guess
scripts/reckon.sh opening-balance 1234 2026-01-31 1000.00
scripts/reckon.sh checkpoint 1234 2026-02-28 1552.43    # prints the reconciliation
make reconcile                                          # re-check every checkpoint
```

**Posting (Phase 3):**

- Every imported row becomes exactly one journal entry, linked to it in
  `journal_entry_evidence` (D039). Running `make post` again only posts
  what's new.
- **Transfers** between my accounts (e.g. a Visa payment from chequing) and
  **cancelled e-Transfers / exact refunds** are paired and routed through
  `asset:clearing`, so they never count as spending, and each account
  matches its own statement on every date (D040).
- Pairing only happens when it's unambiguous. Otherwise the rows are listed
  for review with their ids, and `post-row` settles them (D041, D046).
- If the other half of a transfer arrives in a later import, the row posted
  earlier on a guess is reversed (same date) and re-posted (D042).
- Rules: "description contains TEXT → account", with priority (D044).
  Unmatched rows go to `expense:uncategorized` / `income:uncategorized`.
  Payments to cards reckon doesn't track go to `liability:untracked-cards`.
- e-Transfers and bill payments are ordinary rows: rules categorize them
  (e.g. `add-rule HYDRO expense:utilities`), and a cancelled e-Transfer
  pairs with the original.

**Reconciliation (Phase 3):**

- Opening balance per account, from a statement dated before the first
  import (replacing one reverses the old entry).
- Statement checkpoints (append-only). The report either says RECONCILED
  or names the cause of the gap: unposted rows that close it, a missing
  opening balance, a possible duplicate, or days no export covered (D043).

**Importing (Phase 2):** RBC CSV by column name, exact cents, only the last
4 digits of account numbers, overlap-safe dedupe with review flags,
append-only evidence.

**Ledger (Phase 1):** balanced, append-only journal enforced by the
database; reversals; balances as of a date.

**Skeleton (Phase 0):** `make dev`, `/api/health` with a live badge,
TypeScript types generated from Haskell, the privacy guard, CI.

Tests: 95 examples (hspec + hedgehog properties, including model-based and
database properties). `make check` passes.

There's no UI for any of this yet. That's Phase 6.

## Decisions the owner should check (made while they were away)

The owner asked to keep going without answering these, so the recommended
option was taken. Both are easy to change now, harder later. **D038**:

1. **Payments to credit cards reckon doesn't track** go to
   `liability:untracked-cards`, not spending (the card's purchases were the
   spending). To treat them as spending instead:
   `scripts/reckon.sh add-rule AMEX expense:credit-card` (rules win over
   the guess).
2. **Opening balance** is one entry per account, from a statement balance
   dated before the first imported transaction, against
   `equity:opening-balance`.

Also a scope change, **D045**: pending transactions and debit holds moved
to Phase 5, because CSV exports only contain posted transactions. Pending
rows only appear once screenshots are imported.

## Unverified against real data

Nothing here has been run on a real RBC export yet. When the owner does:

- **The CSV layout** (Phase 2): Account Type, Account Number, Transaction
  Date, Cheque Number, Description 1, Description 2, CAD$, USD$, with
  M/D/YYYY dates. If `make import` rejects a file, the error lists line
  numbers and reasons. Share those, not the file.
- **Credit-card signs** (Phase 3): assumed purchases negative and payments
  positive in RBC's Visa export. If they're the other way round, transfers
  to the card won't pair (the amounts won't be opposite).
- **Keywords** (Phase 3): cancellations are recognized by CANCEL, REVERS,
  RETURN, DECLIN, REFUND; card payments by PAYMENT/PMT plus VISA,
  MASTERCARD, AMEX, AMERICAN EXPRESS or CREDIT CARD. Real descriptions may
  differ. `make post`'s summary shows what was recognized.

## What's next: Phase 4 (shared expenses and receivables)

From [SPEC.md](SPEC.md#phase-4-shared-expenses-and-receivables): split a
payment so others' shares become `receivable:<person>`, record repayments
(often e-Transfers in) against those receivables, and show who owes what.
Phase 3 already creates `receivable:` accounts as assets, so a rule or
`post-row` can use them; Phase 4 adds splitting one row across several
accounts.

Questions to bring to the owner at the start of Phase 4:
- How are people identified: a name typed each time, or a `people` table
  with e-Transfer names attached (so repayments can be matched)?
- Should an incoming e-Transfer from someone who owes money be applied to
  their receivable automatically, or suggested for review?

## Open questions for the owner

1. The two D038 defaults above (confirm or override).
2. Production deployment target for the Phase 8 demo (Fly.io, Render, a VPS,
   or local-only). Doesn't block anything until Phase 8.

## Resolved

- **Phase 2 dedupe design** (2026-09-23): approved as proposed (D029, D030).
- **Phase 1 design** (2026-09-23): D020, D021, D022.
- **Phase 3 scope with only a chequing account** (2026-09-22): keep the card
  and transfer features (fake fixtures), **and** add e-Transfers, bill
  payments, and pending debit holds. (Pending holds later moved to Phase 5,
  D045.)

## Known issues and tech debt

- **Review items repeat.** Until Phase 6 adds a way to resolve them, a later
  overlapping import can flag the same situation again (e.g. the old version
  of a renamed row is "missing" from every newer export).
- **Rules don't re-categorize the past.** A rule added after posting only
  affects rows posted later (D044). Phase 7's "preview against past
  transactions" will address it; until then, rows already posted as
  uncategorized stay there.
- **Settling a review row is by id only.** `post-row` doesn't check that
  the two legs of a transfer you settle by hand actually balance through
  clearing. `make reconcile` will show it if they don't.
- **Posting reads every unposted row** in one transaction. Fine for a
  personal ledger; would need batching at a much larger scale.
- The RBC format and heuristics are unverified (above).
- `string-interpolate` is pinned to `<1` because aeson-typescript doesn't
  compile against 1.x on GHC 9.10 (D017).
- aeson-typescript names record interfaces `I<Name>` with a `<Name>` alias
  (D018). Cosmetic.
- persistent entities are kept in step with the SQL by hand (D028). Every
  table is exercised through persistent in tests.
- `check_journal_entry` runs once per inserted row. Negligible at this scale.
- The frontend has no unit tests yet. Vitest arrives with real display logic
  (Phase 6).
