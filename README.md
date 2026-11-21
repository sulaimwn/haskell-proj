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

**Stack:** Haskell (Servant, persistent) · PostgreSQL · React + TypeScript

## Status

Built in phases. Details: [docs/STATUS.md](docs/STATUS.md).

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
| 8 | Demo dataset and write-up | next |

## Quickstart (Ubuntu)

Prerequisites: GHC 9.10.3 + cabal 3.16 (via ghcup), Node 22, Docker, and a few
system libraries. [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) has copy-paste
setup steps.

```bash
git clone https://github.com/sulaimwn/haskell-proj.git && cd haskell-proj
make dev    # Postgres + migrations + API on :8080 + frontend on :5173
make test   # backend tests (frontend: cd frontend && npm test)
make check  # everything CI runs
make import file=private/rbc-export.csv   # import a real RBC CSV export
make post                                 # turn imported rows into journal entries
scripts/reckon.sh checkpoint 1234 2026-02-28 1552.43   # check against a statement
scripts/reckon.sh split-row 42 expense:food equal alex sam   # share a dinner; `owed` shows who owes what
scripts/reckon.sh import-screenshots 1234 private/screenshots/*.png   # read app screenshots with Claude (needs ANTHROPIC_API_KEY)
```

Open <http://localhost:5173> for the web UI (accounts, transactions, spending,
receivables, a review queue, and CSV and screenshot import). The first build
compiles all Haskell dependencies and takes a while. The API has no login, so
it listens on `127.0.0.1` only (see [docs/PRIVACY.md](docs/PRIVACY.md)).

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
| [CLAUDE.md](CLAUDE.md) | Conventions for anyone (human or AI) changing the code |

## Privacy

This repo contains **no real financial data**. Real exports live in a
gitignored `/private` folder. A pre-commit hook and a CI job both block
data-shaped files anywhere else, and only the last 4 digits of an account
number are ever stored. See [docs/PRIVACY.md](docs/PRIVACY.md).
