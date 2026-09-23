# CLAUDE.md

Guidance for Claude Code (and any developer) working in this repo. Read this
first, then [docs/STATUS.md](docs/STATUS.md) to see where the project is.

## What this is

**reckon** is a personal double-entry ledger. It imports real RBC bank data
(CSV exports and screenshots of the RBC app), turns it into balanced journal
entries, and proves that the ledger reconciles to the cent against real
statements. It never moves money. Stack: Haskell (Servant, persistent)
+ PostgreSQL + React/TypeScript. It is a portfolio project, so every design
decision must be explainable.

## Working agreement

- The project is built in **phases** ([docs/SPEC.md](docs/SPEC.md#phases)).
  Do one phase at a time. At the end of a phase, stop: summarize what was
  built and the key design decisions, open **one PR for the phase**, and wait
  for the owner's review before starting the next one. Don't skip ahead.
- Ask before making decisions that the spec leaves to the owner.
- Before pushing, run `make check` (the same checks CI runs).

## Documentation rule (non-negotiable)

The owner must be able to hand this repo to a new developer at **any**
moment, and have the docs give them a full understanding. So docs are updated
**in the same commit/PR as the code change**, never "later".

| Doc | Its one job | Update it when |
|---|---|---|
| `README.md` | Pitch, status at a glance, quickstart, doc index | Phase completes, quickstart changes |
| `docs/STATUS.md` | **Handoff doc.** What works now, what's next, open questions, known issues | Every PR. Always current. |
| `docs/SPEC.md` | What we're building and the phase plan | Scope changes (agreed with the owner) |
| `docs/ARCHITECTURE.md` | How it's built now: components, flows, layout, invariants and how each is enforced | Structure, tables, flows or invariants change |
| `docs/DECISIONS.md` | Why: numbered decision log with alternatives | Any non-obvious choice. Supersede entries, never delete them |
| `docs/CODE_TOUR.md` | Module-by-module walkthrough, the Haskell idioms used, likely interview questions | New module, new idiom, or significant change to one |
| `docs/DEVELOPMENT.md` | Setup, commands, env vars, troubleshooting | Tooling, commands or env vars change |
| `docs/PRIVACY.md` | Data-handling rules and how they're enforced | Anything touching real data, secrets, or the Claude API |
| `CLAUDE.md` | This file: conventions for whoever edits the code | Conventions change |

Before finishing any task, check: *would a developer reading only the docs be
misled about the current state?* If yes, fix the docs.

## Conventions

- **Descriptive names** (`statementBalanceCents`, not `sb`), and short comments
  that explain *why* where it isn't obvious.
- **Money is never floating point.** `Cents` newtype over `Int64` in Haskell,
  `BIGINT` in SQL, integer cents in TypeScript. Format only at display time.
- **Make invalid states unrepresentable:** a newtype per ID type, and separate
  types for states that behave differently (pending vs posted, provisional vs
  confirmed).
- **Schema changes are SQL migrations** (`make migration name=...`). persistent
  never auto-migrates. Commit the regenerated `db/schema.sql`. Never edit a
  merged migration.
- **Integrity rules live in the database** (constraints, triggers) as well as
  in Haskell. Test them by bypassing Haskell with raw SQL.
- **API types are declared once**, in `backend/src/Reckon/Api/Types.hs` with
  `deriveJSONAndTypeScript`, and added to `typeScriptDeclarations`. Run
  `make codegen`. Never hand-write an API type in TypeScript.
- **JSON:** record fields go over the wire verbatim (camelCase). Enums use
  `enumOptions "<Prefix>"` and become snake_case strings.
- **Haskell style:** GHC2024 plus `OverloadedRecordDot`, `DuplicateRecordFields`
  and `OverloadedStrings` (set in `reckon.cabal`). `deriving stock` / `newtype`
  / `anyclass` explicitly. Qualified imports for containers and text
  (`import Data.Text qualified as Text`). Keep pure logic separate from IO so
  it can be tested without a database.
- **Tests:** hspec for examples, hedgehog for properties (from Phase 1).
  Database tests use `TEST_DATABASE_URL` and fail, not skip, without it.
  Tests never call the real Claude API.
- **Warnings:** the cabal file enables a strict warning set. CI builds with
  `-Werror`.

## Privacy rules (non-negotiable)

Full version: [docs/PRIVACY.md](docs/PRIVACY.md).

- Never store full account numbers. Keep only the last 4 digits.
- Real data lives only in `/private` (gitignored). `/fixtures` is fake data only.
- Secrets (`ANTHROPIC_API_KEY`) come from `.env`, are used only by the
  backend, and are never logged or sent to the frontend.
- Don't weaken `scripts/check-private-data.sh` or the pre-commit hook to
  make a commit go through.

## Commands

```bash
make dev        # Postgres + migrations + API (:8080) + frontend (:5173)
make test       # backend tests against reckon_test
make check      # everything CI runs, run before pushing
make codegen    # after changing backend/src/Reckon/Api/Types.hs
make migration name=...   # new SQL migration; then `make migrate`
make import file=private/export.csv   # import a real RBC CSV
```

Toolchain: GHC 9.10.3, cabal 3.16.1.0 (via ghcup), Node 22, Docker. See
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Layout

```
backend/     Haskell: src/Reckon/* (library), app/ (server), cli/ (reckon-cli), codegen/, test/
frontend/    React + Vite; src/api/generated.ts is GENERATED
db/          migrations/ (schema source of truth), schema.sql (generated dump)
fixtures/    fake data only
private/     real data, gitignored
scripts/     bash behind the Makefile targets
docs/        see the table above
```

## Gotchas

- Template Haskell's stage restriction: options used inside a splice must be
  defined in another module (hence `Reckon.Api.JsonOptions`).
- dbmate errors on an empty `db/migrations/`. `scripts/migrate.sh` and CI skip
  the step until the first migration exists.
- The first `cabal build` compiles all dependencies (10–20 min). CI caches
  the cabal store keyed on the freeze file.
- `backend/cabal.project` pins `string-interpolate <1` because aeson-typescript
  breaks against 1.x (DECISIONS D017). After changing dependencies, run
  `cabal freeze` in `backend/` and commit `cabal.project.freeze`.
- Generated TS records look like `type Foo = IFoo` + `interface IFoo`
  (aeson-typescript convention). Import the plain `Foo`.
- The journal is append-only: tests can't delete rows. Give every test its
  own accounts via `uniqueSuffix` (test/Reckon/TestSupport.hs). `make test`
  and `make check` recreate `reckon_test` on each run.
- Database rules must be tested by bypassing Haskell (raw SQL via
  `rawExecute`/`rawSql`), and a transaction must COMMIT for the deferred
  balance trigger to fire. Don't test it inside a rolled-back transaction.
- `Reckon.Database.Schema` must match the SQL by hand. When a migration
  changes a table, update the entity in the same PR.
- Import tests must not reuse a bank account: use `uniqueLast4` and
  `fixtureFor last4 name` (ImportSpec) to rewrite the fixtures' fake account
  number, otherwise a second test sees "already imported".
- Imported evidence (`raw_bank_rows` etc.) is append-only too. A wrong import
  is fixed by fixing the parser, `make db-destroy`, and re-importing from
  `/private`.
- Records sharing a field name (e.g. `transactionDate` on `RowKey` and
  `IncomingRow`) can't use record-update syntax. Build with the constructor.
- `OverloadedRecordDot` needs the record's fields in scope: import
  `AppEnv (..)`, not just `AppEnv`, to use `env.databasePool`.
