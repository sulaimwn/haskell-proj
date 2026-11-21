# reckon

A personal double-entry ledger that **reconciles to the cent** against real
bank statements.

reckon imports my real RBC banking data (CSV exports, plus screenshots of the
RBC mobile app read by Claude) and turns it into balanced, append-only journal
entries. Then it proves its numbers are right: for every bank account, the
ledger balance on a statement date must equal the balance printed on the
statement. When it doesn't, reckon shows exactly which transactions explain
the gap.

It never moves money. It's a ledger of evidence, with the same relationship
to my bank that a bank's internal ledger has to the payment networks.

**Stack:** Haskell (Servant, persistent, megaparsec) · PostgreSQL · React + TypeScript

## Try it

No real data and no API key needed: `make demo` runs the whole app on an
invented three-month dataset, in its own database.

```bash
git clone https://github.com/sulaimwn/haskell-proj.git && cd haskell-proj
make demo        # fake data, own database; open http://localhost:5173
```

Setup for Ubuntu (GHC 9.10, cabal, Node 22, Docker) is in
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). The first build compiles all
Haskell dependencies and takes a while.

The demo has a reconciled account and one that isn't (with the rows that
explain it), a dinner split three ways and one friend's repayment still to
settle, a restaurant hold that posted with a tip, a gas hold that posted lower,
a hotel hold that never posted, two overlapping screenshots, ambiguous
transfers waiting for a decision, and a payment coming due. Where each is:
[fixtures/demo/README.md](fixtures/demo/README.md).

## What it does

- **Imports** RBC CSV exports (exact cents, overlap-safe, idempotent) and
  **screenshots** of the app (read by Claude, then checked by code).
- **Posts** every row as one journal entry: rules categorize it, transfers
  between my accounts and cancelled e-Transfers pair up and never count as
  spending, and anything it can't decide is left for a person.
- **Reconciles**: statement balance against ledger balance, per account, with
  the cause of any gap named.
- **Shares expenses**: split a payment with friends (my share is the
  remainder), track who owes what, suggest repayments.
- **Categorizes with a small rule language**, with a live preview against the
  past, and **reminds** me of what it notices on its own (a month with no
  statement, screenshot rows the bank never confirmed, a payment due).
- A web UI for all of it, and a command line for the same operations.

## How it works

```
 CSV exports ─────────┐                                           ┌─► reconciliation report
                      ├─► evidence ─► journal entries ─► ledger ──┼─► spending, receivables
 screenshots ─ Claude ┘  (append-only)  (one per row)  (balanced,  └─► reminders
   (read, then validated)                               append-only)
```

Three ideas carry the design:

1. **Evidence is separate from the ledger.** An imported row, or a validated
   reading of a screenshot, is stored once and never changed. Journal entries
   point at the evidence that justifies them. Fixing a mistake means reversing
   an entry (dated like the original, so no balance on any date moves) and
   posting again; nothing is edited or deleted.
2. **Make it provable.** The ledger must equal the bank's statement to the
   cent. Every rule that makes that true is enforced where it can't be
   bypassed (below), and what can't be decided automatically is shown to a
   person instead of guessed.
3. **Untrusted input is checked in code.** The model only *transcribes* a
   screenshot. The year, the exact cents, and the signs are worked out in
   Haskell, and one bad row rejects the whole reading.

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) has the components, flows and
tables; [docs/CODE_TOUR.md](docs/CODE_TOUR.md) walks through every module and
the Haskell idioms used; [docs/DECISIONS.md](docs/DECISIONS.md) records why.

## The invariants, and how each is enforced

Each is enforced at more than one level: a type that can't hold the bad value,
a database rule that rejects it even if Haskell is bypassed, and tests
(examples, properties, and raw SQL that goes around Haskell). The full list,
with the tests, is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#invariants).

| Invariant | Types | Database | Tests |
|---|---|---|---|
| Every journal entry balances to zero | `BalancedLines` smart constructor | deferred constraint trigger | hedgehog property; raw SQL |
| The journal never changes | | `BEFORE UPDATE/DELETE/TRUNCATE` triggers | raw SQL |
| A reversal cancels its original, once | `postReversal` | trigger + `UNIQUE (reverses_entry_id)` | examples |
| Money is exact | `Cents` over `Int64`, no `Num` | `BIGINT` | amounts parsed from text; integer cents in TypeScript |
| An imported row is stored once, identical same-day rows are all kept | `planImport` | `UNIQUE (account, date, fingerprint, occurrence)` | property over overlapping, shuffled, partial exports |
| Only the last 4 digits of an account number exist | `Last4` | `CHECK (last4 ~ '^[0-9]{4}$')` | scan of every stored column |
| Ledger = opening + posted rows, on every date | one entry per row; reversals dated like the original | `journal_entry_evidence` | property over random exports; mutation checks |
| Transfers and cancellations are never spending | both legs through `asset:clearing` | | property: clearing nets to zero |
| Rows are paired only when unambiguous | `pairUniquely` | | property: pairs are mutual |
| A split's parts add up exactly | `Split` smart constructor | balance trigger | property over random splits |
| Nothing the model says is trusted until validated | `parseExtraction` | all-or-nothing transaction | fakes, never the real API |
| The API key never appears anywhere | `ApiKey` with a redacted `Show` | | test over every error text |
| Only my browser can use the API | | | loopback bind, `Host` allowlist, JSON-only writes; mutation-tested |
| A saved rule always parses, in one canonical form | `renderRule` / `parseRule` | `UNIQUE (rule_text)` | round-trip property |
| A job runs on one worker, and a recurring job never piles up | | `SKIP LOCKED`, partial unique index | a two-connection concurrency test |

## The parts that were hard

- **Deduplicating overlapping exports** ([D029–D030](docs/DECISIONS.md)).
  A row's identity is (account, date, fingerprint of its description and
  amount, occurrence), where *occurrence* counts identical rows on one day, so
  two $4.50 coffees stay two. Importing an overlapping export adds only rows
  whose occurrence isn't stored yet. A renamed row is flagged as a possible
  duplicate and a row that vanished from a newer export is flagged missing:
  both for a person, never guessed.
- **Joining overlapping screenshots** ([D056](docs/DECISIONS.md)). A scroll is
  several screenshots that share rows. They're joined by their longest overlap
  of equal rows, keeping genuinely identical rows, and warn when the overlap is
  ambiguous, missing, or in the wrong order.
- **Screenshots are provisional** ([D057–D059](docs/DECISIONS.md)). What's read
  is posted as a provisional entry and resolved, by reversal, when the bank's
  CSV arrives: confirmed, already there, replaced (a hold that posted for a
  different amount, like a tip), or released (a hold that never posted). A row
  matches only when it's the other's only candidate.
- **Explaining a reconciliation gap** ([D043](docs/DECISIONS.md)). When the
  ledger and a statement disagree, a pure function names the cause: unposted
  rows that would close it exactly, a missing opening balance, a possible
  duplicate, rows read from screenshots the statement doesn't have yet, or days
  no export covers.
- **A rule language** ([D067–D069](docs/DECISIONS.md)): `when description
  starts with "UBER" and amount < -50.00 then categorize expense:transport`,
  parsed with megaparsec with errors that point at the line and column, stored
  as canonical text, previewed against past rows, applied by reverse-and-repost.

## Extraction accuracy

**Not measured yet.** The pipeline (prompt, schema, validation, alignment,
matching) has only ever been run against hand-written fake replies and a local
stand-in for the API, never against the real API or a real RBC screenshot, so
there is no accuracy number to report, and inventing one would be wrong.

What exists is the instrument: `scripts/reckon.sh eval-screenshots DIR` reads
pairs of screenshot and hand-written label from `private/eval`, calls the model,
and scores rows found (matched by date and amount), rows missed and rows
invented, and how many of the found rows have the right description, the right
pending/posted section and the right running balance, so different models can be
compared on the owner's own screenshots. Running it on a handful of real screenshots is
the first thing to do ([docs/STATUS.md](docs/STATUS.md#unverified-against-real-data)).

## Known limitations

- **Nothing has run on real data yet**: not the CSV layout assumptions, the
  credit-card sign convention, the e-Transfer keywords, or the model's reading
  of the real app. Each is listed, with how to check it, in
  [docs/STATUS.md](docs/STATUS.md).
- **CAD only, and RBC only.** A USD row is rejected with a line number rather
  than guessed at (D023).
- **No login.** It's built for one person's machine: it listens on loopback only
  and refuses other host names and non-JSON writes (D061). It needs real
  authentication before it goes anywhere else.
- Splits are equal shares in the UI (the API takes exact shares); rules have no
  `or` or regular expressions; the reminder thresholds are guesses; there is no
  paging past the newest 200 transactions.
- Single user, single currency, single institution: by design, for now.

## Status

Built in phases ([docs/SPEC.md](docs/SPEC.md)); details and what's next in
[docs/STATUS.md](docs/STATUS.md).

| Phase | | Status |
|---|---|---|
| 0 | Environment and skeleton | ✅ done |
| 1 | Ledger core: balanced, append-only journal, property tests | ✅ done |
| 2 | RBC CSV import with idempotent, overlap-safe dedupe | ✅ done |
| 3 | Evidence → entries, transfer pairing, statement reconciliation | ✅ done |
| 4 | Shared expenses and receivables | ✅ done |
| 5 | Screenshot ingestion with Claude | ✅ done |
| 6 | Frontend: accounts, transactions, spending, receivables, review queue, import | ✅ done |
| 7 | A categorization rule language, scheduled jobs and reminders | ✅ done |
| 8 | Demo dataset and write-up | ✅ done |

## Everyday commands

```bash
make demo   # the app on fake data, in its own database
make dev    # Postgres + migrations + API on :8080 + frontend on :5173 (your data)
make test   # backend tests (frontend: cd frontend && npm test)
make check  # everything CI runs
make import file=private/rbc-export.csv   # import a real RBC CSV export
make post                                 # turn imported rows into journal entries
scripts/reckon.sh checkpoint 1234 2026-02-28 1552.43   # check against a statement
scripts/reckon.sh                         # every command
```

The full import → post → reconcile walkthrough is in
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#from-import-to-a-reconciled-ledger).

## Documentation

| | |
|---|---|
| [docs/STATUS.md](docs/STATUS.md) | Where the project is right now. **Start here if you're picking it up.** |
| [docs/SPEC.md](docs/SPEC.md) | What reckon does and the phase plan |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How it's built, and the invariants it guarantees |
| [docs/DECISIONS.md](docs/DECISIONS.md) | Why it's built that way |
| [docs/CODE_TOUR.md](docs/CODE_TOUR.md) | A guided walk through the code and the Haskell idioms it uses |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | Setup, commands, troubleshooting |
| [docs/PRIVACY.md](docs/PRIVACY.md) | How real financial data is kept out of the repo |
| [fixtures/demo/README.md](fixtures/demo/README.md) | The demo dataset and where each hard case is |
| [CLAUDE.md](CLAUDE.md) | Conventions for anyone (human or AI) changing the code |

## Privacy

This repo contains **no real financial data**. Real exports live in a
gitignored `/private` folder. A pre-commit hook and a CI job both block
data-shaped files anywhere else, and only the last 4 digits of an account
number are ever stored. See [docs/PRIVACY.md](docs/PRIVACY.md).
