# Status

**The handoff doc.** If you're picking this project up, read this first,
then [CLAUDE.md](../CLAUDE.md). Updated in every PR.

_Last updated: 2026-09-22, end of Phase 0._

## Where we are

**Phase 0 (environment and skeleton) is complete** and waiting for the
owner's review. Phase 1 starts after that.

| Phase | Status |
|---|---|
| 0: Environment and skeleton | ✅ done, in review |
| 1: Ledger core | ⏭ next |
| 2–8 | not started |

## What works today

- `make dev` starts Postgres (Docker), applies migrations, builds and runs
  the Haskell API on :8080 and the Vite frontend on :5173. Ctrl-C stops the
  API and frontend.
- `GET /api/health` returns `{"databaseStatus": "reachable" | "unreachable",
  "serverVersion": "..."}` and keeps answering while Postgres is down. It
  recovers on its own when Postgres comes back.
- The frontend shows a live status badge (API down / database down / all
  good), polling every 10 s.
- TypeScript API types are generated from the Haskell types (`make codegen`),
  committed, and checked for freshness in CI.
- Migration pipeline: dbmate in Docker migrates the `reckon` and
  `reckon_test` databases and dumps `db/schema.sql`. Verified end to end
  with a throwaway migration. There are no real migrations yet.
- Tests: 13 hspec examples, covering config parsing, the JSON wire format and
  generated TypeScript, and the health endpoint against a real database and a
  dead one.
- Privacy guard: `.gitignore` + pre-commit hook + CI job, verified to block
  `private/**`, `.env*` and stray data files, and to allow `fixtures/**`.
- CI (GitHub Actions): repo hygiene (privacy guard, shellcheck), backend
  (`-Werror` build, tests against Postgres 17, codegen check), frontend (lint,
  typecheck, build).

## Verified on

A clean Ubuntu 24.04 container: GHC 9.10.3, cabal 3.16.1.0, Node 22,
Docker 29, with the apt packages listed in DEVELOPMENT.md. `make check`
passes. `make dev` was run and checked in headless Chromium: the badge showed
"API ok · database ok", then "database unreachable" after stopping Postgres.

## What's next: Phase 1 (ledger core)

From [SPEC.md](SPEC.md#phase-1-ledger-core-no-ui-no-imports):

1. Migrations for `ledger_accounts`, `journal_entries`, `journal_lines`.
2. A deferred constraint trigger that rejects any entry whose lines don't sum
   to zero, plus append-only enforcement (no UPDATE or DELETE on posted
   entries).
3. Haskell domain types: `Cents`, ID newtypes, account types, entries. Functions
   to post an entry, post a reversal, and compute a balance as of a date.
4. Tests: a hedgehog property (random sequences of entries and reversals keep
   everything balanced), raw-SQL tests showing the database itself rejects
   unbalanced entries, and a test that reversal restores the prior balances.

Design questions to settle at the start of Phase 1, before coding:

- Sign convention for `journal_lines.amount_cents` (proposed: debits
  positive, credits negative, so every entry sums to zero, and balances
  are presented with the natural sign for each account type).
- Whether entries are posted atomically with their lines via a single
  function or a stored procedure.

## Open questions for the owner

1. Production deployment target for the Phase 8 demo (Fly.io, Render, a VPS, or
   local-only). This doesn't block anything until Phase 8.

## Resolved

- **Phase 3 scope with only a chequing account** (resolved 2026-09-22): keep
  the card and transfer features as specced (tested on fake fixtures), and
  **add** Interac e-Transfers (including cancelled ones), bill payments, and
  pending debit holds. See [SPEC.md, Phase 3](SPEC.md#phase-3-turning-evidence-into-entries).

## Known issues and tech debt

- `string-interpolate` is pinned to `<1` in `backend/cabal.project`, because
  aeson-typescript doesn't compile against 1.x on GHC 9.10 (DECISIONS D017).
  Revisit when aeson-typescript releases a fix.
- aeson-typescript names record interfaces `I<Name>` and exports `<Name>` as an
  alias (DECISIONS D018). Cosmetic only.
- The frontend has no unit tests yet (nothing to test beyond the badge).
  Vitest will be added once there is real display logic, such as money
  formatting.
- The first backend build takes 10–20 minutes (dependency compilation). CI
  caches the cabal store.
- CI is green on GitHub for the Phase 0 PR. The first backend run took about 13 minutes
  (cold dependency cache). Later runs reuse the cached cabal store.
