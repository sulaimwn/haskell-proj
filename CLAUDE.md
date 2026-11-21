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
- **Rules are text** (D067-D069): `posting_rules.rule_text` is the only copy of a rule, always the
  canonical `renderRule` of a parsed rule. Add a feature to the language by changing `Rules.Language`
  (parser, renderer, the round-trip generator in `LanguageSpec`) and `Rules.Eval` together.
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
- **API security (D061):** the server is login-less, so it binds loopback and runs behind
  `hostGuard` and `jsonOnlyWrites` (`Reckon.Security`). Don't bypass them, don't add a route
  that returns data without going through `Server.application`, and don't widen the bind.
- **JSON:** record fields go over the wire verbatim (camelCase). Enums use
  `enumOptions "<Prefix>"` and become snake_case strings.
- **Haskell style:** GHC2024 plus `OverloadedRecordDot`, `DuplicateRecordFields`
  and `OverloadedStrings` (set in `reckon.cabal`). `deriving stock` / `newtype`
  / `anyclass` explicitly. Qualified imports for containers and text
  (`import Data.Text qualified as Text`). Keep pure logic separate from IO so
  it can be tested without a database.
- **Frontend:** strict TypeScript; types only from `generated.ts`; money is integer cents and
  goes to and from text only through `lib/money.ts`; every action uses `useAction` (it
  invalidates all queries); pages show the server's own `problem`/`message` text verbatim.
- **Tests:** hspec for examples, hedgehog for properties (from Phase 1).
  Database tests use `TEST_DATABASE_URL` and fail, not skip, without it.
  Tests never call the real Claude API.
- **Warnings:** the cabal file enables a strict warning set. CI builds with
  `-Werror`. GHC doesn't recompile a module when only warning flags change, so `make check` builds in
  its own directory (`backend/dist-newstyle-werror`) that only ever holds `-Werror` objects. A plain
  `cabal build --ghc-options=-Werror` in `dist-newstyle` can pass on cached objects and hide warnings
  that CI's clean build will reject.

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
make demo       # the same, on fake data in its own database (reckon_demo); nothing real is touched
make test       # backend tests against reckon_test
make check      # everything CI runs, run before pushing
make codegen    # after changing backend/src/Reckon/Api/Types.hs
make migration name=...   # new SQL migration; then `make migrate`
make import file=private/export.csv   # import a real RBC CSV
make post       # post imported rows to the journal
make reconcile  # compare the ledger with every recorded statement balance
make owed       # what friends owe you
make provisional  # rows read from screenshots that no bank CSV has confirmed yet
cd frontend && npm test   # frontend tests (also part of make check)
scripts/reckon.sh COMMAND ...   # any reckon-cli command (run-checks, reminders, add-due-date, post-row, recategorize, add-rule, rules, check-rule, apply-rule, delete-rule, add-person, split-row, spending, import-screenshots, release-provisional, eval-screenshots, opening-balance, checkpoint)
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
- `postPendingRows` posts **every** unposted row in the database, and rules
  are global. Posting tests use a `Scenario` (PostingSpec): unique account
  numbers, a unique year (so pairing windows never overlap another test's
  rows) and a unique description tag for rules. Assert only on the
  scenario's own rows (DECISIONS D047).
- `hostGuard` reads Warp's `requestHeaderHost`, falling back to the `Host` header, because
  `Network.Wai.Test` requests built by hand set only the header. A guard test must also run over
  a real socket (`testWithApplication`, as ApiSpec does), and Servant already answers 415 for
  routes with a JSON `ReqBody`, so test `jsonOnlyWrites` on a bare `Application`.
- API handlers get their wording from `Reckon.Messages`, the same module the CLI uses. Add a
  refusal there, once, and map it to a status in `Server.hs` (`refuse`).
- Frontend component tests use `fakeBackend` (`src/testing.tsx`): it answers `"METHOD /path"`
  from a table and fails the test on an unexpected request. Assert on the JSON a form sent, not
  just on what the page showed afterwards.
- Rules are global, like people, and `postPendingRows` posts every unposted row, so a rule in a test
  must only match its own scenario's rows: put the scenario's tag in the description text it
  matches (`bistro scenario` in RulesSpec) and in its account and friend names.
- `Classify.Rule` is the planner's *resolved* rule (account ids, `Outcome`); `Rules.Language.Rule` is
  what the text says (account names). `Rules.loadRules` turns one into the other. Tests of the pure
  planner build `Classify.Rule` directly (`containsRule` for the simple case).
- The job queue is a global singleton (one pending `run_checks` job in the whole database, by a unique
  index), so a queue test starts with `clearQueue` (JobsSpec) and passes its own clock. The test
  environment's connection pool has **one** connection: a test that needs two workers builds its own pool
  (`createDatabasePool url 2`), and runs the second worker on a thread so a missing lock fails the test
  instead of hanging it.
- Anything that depends on "today" reads `env.currentTime` (D072), because every scenario lives in a
  made-up future year. Tests that need a date set it: `env {currentTime = pure (UTCTime day 0)}`.
- **The demo must keep working and keep matching its README.** `scripts/seed-demo.sh` asserts what
  `fixtures/demo/README.md` promises and runs in `make check` (`scripts/demo.sh --check`). If a change to
  posting, matching or reconciliation alters an outcome, fix the code or deliberately update the README and the
  `expect` lines together. Fake merchants each have their own invented name: a shared word makes the pending-hold matcher
  (D057) match unrelated rows.
- Keep decisions in pure modules (`Posting.Classify`, `Reconcile.Explain`)
  and IO in their callers. Pure planners are generic in their id and
  account types so tests can use `Int` and `Text`.
- A row is "posted" when it has a `journal_entry_evidence` link to an entry
  that isn't reversed. There's no status column; don't add one. Correct a
  posting by reversing it, dated like the original, then posting again.
- Replace a posted row's entry only through `Posting.repostRow` (reverse
  dated like the original, then post). It refuses rows whose entry touches
  `asset:clearing`. Anything that can refuse must validate *before* it writes.
- `people` (name, `match_text`) is global like rules. Tests that add people
  derive names and match texts from the scenario's tag (SharingSpec), and the
  planner takes people as an argument so its tests need no database.
- Shared test helpers (`Scenario`, `importCsv`, `entryLinesForRow`, ...) live in
  `test/Reckon/ScenarioSupport.hs`. `postPendingRows` posts every unposted
  row, so a test must only assert on its own scenario's rows.
- **Never call the real Claude API from a test.** `Reckon.Anthropic.Extractor` is a function
  (image -> the model's reply text): tests pass fakes (`scripted` in ScreenshotSpec), recorded
  fake replies from `fixtures/screenshots`, or the in-process stub in AnthropicSpec. The key is an
  `ApiKey` whose `Show` is redacted: keep it that way, and build errors from the response, not the
  request.
- Everything the model says is untrusted until `Screenshot.Extraction.parseExtraction` accepts it.
  Do arithmetic, years and signs in code, not in the prompt. A new field means changing the schema,
  the prompt, `parseRawRow`, the fixtures and the spec together.
- A screenshot row is "open" until it has a `provisional_resolutions` row. Resolve one only by
  reversing its entry dated like the original (`reverseEntryOf`), never by editing. The
  reconciliation identity includes open provisional rows (DECISIONS D059).
- `-Wpartial-fields` rejects record fields on only some constructors of a sum type. Put the record
  in its own type (`Imported ImportedScreenshots`).
- GHC 9.10's Prelude exports `foldl'`: importing it from `Data.List` is a redundant-import error
  under `-Werror`.
- Statement balances and opening balances are entered in the **natural**
  sign (money in chequing, money owed on a card). Convert with
  `naturalBalance` at the edges; the ledger stores raw debits (+) and
  credits (−).
- `make migrate` rewrites `db/schema.sql` (and so do `make test`, `make check` and `make dev`, which run it).
  Check `git diff db/schema.sql` right before every commit, not just after the migration you wrote. A newer Postgres patch release can
  add noise to that dump (`ALTER TABLE ... SET (pg_attver=...)` lines, a
  changed "Dumped from database version" comment). Strip it before committing
  so the diff shows only the real schema change.
