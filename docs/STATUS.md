# Status

**The handoff doc.** If you're picking this project up, read this first,
then [CLAUDE.md](../CLAUDE.md). Updated in every PR.

_Last updated: 2026-11-20, end of Phase 5._

## Where we are

**Phase 5 (screenshot ingestion with Claude) is complete**, except that it
has never talked to the real API (see "Unverified" below). Phases 3, 4 and 5
are stacked on one branch and in one PR, because the owner asked for work to
continue without waiting for review ([PR #4](https://github.com/sulaimwn/haskell-proj/pull/4),
one commit per phase, so they can be reviewed separately). Nothing has been
merged by Claude. Phase 6 (the frontend) is next.

| Phase | Status |
|---|---|
| 0: Environment and skeleton | ✅ merged ([PR #1](https://github.com/sulaimwn/haskell-proj/pull/1)) |
| 1: Ledger core | ✅ merged ([PR #2](https://github.com/sulaimwn/haskell-proj/pull/2)) |
| 2: RBC CSV import | ✅ merged ([PR #3](https://github.com/sulaimwn/haskell-proj/pull/3)) |
| 3: Evidence → entries, transfers, reconciliation | ✅ done, in review ([PR #4](https://github.com/sulaimwn/haskell-proj/pull/4)) |
| 4: Shared expenses and receivables | ✅ done, same PR (stacked on 3) |
| 5: Screenshot ingestion with Claude | ✅ done, same PR (stacked on 4) |
| 6: Frontend | ⏭ next |
| 7–8 | not started |

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

**Screenshots (Phase 5):**

```bash
# in .env: ANTHROPIC_API_KEY=sk-ant-...   (and optionally ANTHROPIC_MODEL)
scripts/reckon.sh import-screenshots 1234 private/screenshots/top.png private/screenshots/next.png
scripts/reckon.sh provisional                    # what's waiting on the bank's CSV (make provisional)
make post                                        # after importing the CSV: confirms and replaces them
scripts/reckon.sh release-provisional 12         # a pending hold that never posted
scripts/reckon.sh eval-screenshots private/eval  # score the model against labelled screenshots
```

- A screenshot is read by Claude through a small HTTP client (`Reckon.Anthropic`). The model only
  **transcribes** (date, description and amount as displayed, direction, pending or posted); the
  year, exact cents and signs are worked out in code, and **anything off rejects the whole reading**
  and stores nothing (D054, D055).
- Overlapping screenshots of one scroll are **joined by their overlap**, keeping genuinely identical
  rows (two coffees), and warn on ambiguity, no overlap, or the wrong order (D056).
- What's read becomes **provisional entries** in the ledger. The bank's CSV later **confirms** them
  (the provisional entry is reversed, dated like the original, and the CSV row is posted). Rows the
  CSV already had are never posted; a **pending hold** that posted for a different amount is replaced
  by its posted version; a released hold is reversed by hand (D057, D058).
- Rows the model marked uncertain are kept but **never posted**. Rows cut off at a screen edge are
  skipped. The reconciliation report names open provisional rows as the reason a statement is behind
  (D059).
- The same image is never read twice (SHA-256), and nothing but the validated reply is stored: not
  the image.

**Shared expenses (Phase 4):**

```bash
scripts/reckon.sh add-person alex "ALEX SMITH"            # once per person
scripts/reckon.sh split-row 42 expense:food equal alex sam  # or alex=45.00 sam=25.00
scripts/reckon.sh post-row 57 receivable:alex             # Alex's e-Transfer settles his share
scripts/reckon.sh owed                                    # who owes what (make owed)
scripts/reckon.sh spending 2026-03-01 2026-03-31          # my share only
scripts/reckon.sh recategorize 42 expense:restaurants     # move one posted row
```

- A split is **one entry** with a line per participant; my share is the
  remainder, so the parts always add up exactly (D049). Odd cents go to me.
- A friend's share sits in `receivable:<name>`, so reported spending counts
  only my share (D052). Repayments credit the receivable.
- Money in whose description contains a person's text is **suggested** as
  their repayment, not posted as income and not applied automatically
  (D050). `make post` prints the exact command.
- Replacing a posted row's entry reverses the old one on its original date
  (balances on every date don't change) and is refused for transfer and
  cancelled-pair legs (D051).

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

Tests: 199 examples (hspec + hedgehog properties, including model-based and
database properties; none call the real API). `make check` passes.

There's no UI for any of this yet. That's Phase 6.

## Decisions the owner should check (made while they were away)

The owner asked to keep going without answering these, so the recommended
option was taken. All are easy to change now, harder later. **D038**:

1. **Payments to credit cards reckon doesn't track** go to
   `liability:untracked-cards`, not spending (the card's purchases were the
   spending). To treat them as spending instead:
   `scripts/reckon.sh add-rule AMEX expense:credit-card` (rules win over
   the guess).
2. **Opening balance** is one entry per account, from a statement balance
   dated before the first imported transaction, against
   `equity:opening-balance`.

3. **Repayments are suggested, not applied automatically** (D050). A friend's
   e-Transfer is listed for review with the command to apply it. If the
   owner would rather have a single unambiguous match applied on its own, it's
   a small change in `Reckon.Posting.Classify`, but a wrong match would then
   be silent.
4. **Odd cents in an equal split go to the owner first** (D049).

5. **The default model is `claude-opus-5-5`** (D054), chosen without the
   owner. It's the most capable but also the costliest way to read a
   screenshot. Set `ANTHROPIC_MODEL` to try another, and use
   `eval-screenshots` to compare them on your own screenshots.
6. **Screenshots are read from the command line**, not uploaded from a web
   page (D060): the upload page comes with the frontend in Phase 6. The
   account is named by its last 4 digits and must already have had a CSV imported.

Pending transactions and debit holds (scope change **D045**) were built in
Phase 5, as described above.

## Unverified against real data

**Phase 5 has never talked to the real Anthropic API or seen a real RBC
screenshot.** Everything is tested against fakes: scripted replies,
recorded fake JSON, and a local stub server (and the CLI was run end to end
against that stub). So, before relying on it:

1. **Run it once on real screenshots** and look at the result. A single
   `import-screenshots` and `provisional` will show whether the prompt and
   schema work on the real app's screens.
2. **Run `eval-screenshots`** on a handful of labelled screenshots in
   `private/eval` for the first real accuracy numbers. Try more than one model.
3. Things that are assumptions until then: how the app shows dates ("Feb 14",
   "Today"), amounts and pending sections; that no description legitimately
   has nine digits in a row (such a reading is rejected as a possible account
   number); the matching windows (3 days, 7 for a hold) and "a word in
   common" rule (D057); and that the API's request and response shapes in
   `Reckon.Anthropic` are exactly as the current API expects (they follow its
   documentation, and a failure would show as a clear `ApiError`).

Nothing else here has been run on a real RBC export yet either. When the owner does:

- **The CSV layout** (Phase 2): Account Type, Account Number, Transaction
  Date, Cheque Number, Description 1, Description 2, CAD$, USD$, with
  M/D/YYYY dates. If `make import` rejects a file, the error lists line
  numbers and reasons. Share those, not the file.
- **How the sender appears in an e-Transfer description** (Phase 4). A
  person's `match_text` is whatever you choose, so any format works, but pick
  it from a real row (D053).
- **Credit-card signs** (Phase 3): assumed purchases negative and payments
  positive in RBC's Visa export. If they're the other way round, transfers
  to the card won't pair (the amounts won't be opposite).
- **Keywords** (Phase 3): cancellations are recognized by CANCEL, REVERS,
  RETURN, DECLIN, REFUND; card payments by PAYMENT/PMT plus VISA,
  MASTERCARD, AMEX, AMERICAN EXPRESS or CREDIT CARD. Real descriptions may
  differ. `make post`'s summary shows what was recognized.

## What's next: Phase 6 (frontend)

From [SPEC.md](SPEC.md#phase-6-frontend): accounts overview (balances, reconciliation status),
an import page (CSV and screenshots), the review queue, the transaction list (filter, split with
friends), spending by category per month (excluding transfers and friends' shares), and
receivables. Everything the CLI does today becomes an HTTP endpoint with generated TypeScript
types (`Reckon.Api.Types`) and a page.

Things to decide at the start of Phase 6:
- Screenshot upload: files go to the backend over HTTP (multipart), which calls the API. The key
  never reaches the browser.
- The review queue is where import flags (D031), ambiguous pairings (D041), possible repayments
  (D050), uncertain screenshot rows and open provisional rows all land today as CLI text.
- Whether to add a login before anything is deployed (Phase 8). It's single-user and local so far.

## Open questions for the owner

1. The D038, D050 and D054 defaults above (confirm or override).
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

- **Screenshot rows can't be corrected by hand.** A misread row stays as read until the CSV
  confirms or replaces it; `release-provisional` only handles holds that never posted. Phase 6's
  review queue is the place for correcting one.
- **Screenshots of a card account** work like any other, but a card's provisional entries use
  the same sign rules as its CSV (purchases negative), which is itself unverified.
- **One scroll per command.** Two separate scrolls can be imported in two commands (the rows
  they share are skipped), but the join between them is not checked for gaps.
- **The model is called one image at a time**, sequentially, with no cost estimate before it runs.
- **Review items repeat.** Until Phase 6 adds a way to resolve them, a later
  overlapping import can flag the same situation again (e.g. the old version
  of a renamed row is "missing" from every newer export).
- **Rules don't re-categorize the past.** A rule added after posting only
  affects rows posted later (D044). `recategorize` fixes one row at a time
  (D051). Phase 7's "preview against past transactions" is the bulk answer.
- **A typo in an account name creates a new account**, and accounts can't be
  deleted (append-only). `make db-psql`, `SELECT name FROM ledger_accounts`
  shows what exists. Worth validating against known accounts (or a
  confirmation) before the UI.
- **A split can't be edited, only replaced.** Splitting again reverses the
  previous split and posts a new one, leaving the history in the journal.
- **Person names are lower-case slugs** (`alex`), not display names. A
  display name belongs with the Phase 6 UI.
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
