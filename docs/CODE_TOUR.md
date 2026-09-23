# Code tour

A guided walk through the code, in the order a request flows through it. Each
section explains **what the module does**, **the Haskell ideas it uses**, and
**questions an interviewer might ask**, with answers. Read it next to the
code.

This grows with every phase. Every new module gets a section.

---

## Contents

- [The shape of the backend](#the-shape-of-the-backend)
- [`app/Main.hs`: startup](#appmainhs-startup)
- [`Reckon.Config`: configuration as a pure function](#reckonconfig-configuration-as-a-pure-function)
- [`Reckon.Database`: the pool and the ping](#reckondatabase-the-pool-and-the-ping)
- [`Reckon.App`: the ReaderT pattern](#reckonapp-the-readert-pattern)
- [`Reckon.Api`: the API is a type](#reckonapi-the-api-is-a-type)
- [`Reckon.Api.Types` and `JsonOptions`: one definition, two languages](#reckonapitypes-and-jsonoptions-one-definition-two-languages)
- [`Reckon.Server`: handlers](#reckonserver-handlers)
- [`codegen/Main.hs` and `Reckon.Api.TypeScript`](#codegenmainhs-and-reckonapitypescript)
- [The ledger (Phase 1)](#the-ledger-phase-1)
- [Importing bank exports (Phase 2)](#importing-bank-exports-phase-2)
- [Tests](#tests)
- [Frontend](#frontend)
- [Glossary](#glossary)

---

## The shape of the backend

`backend/reckon.cabal` defines five **components** that share one library:

| Component | Directory | What it is |
|---|---|---|
| `library` | `src/` | All the real code. Everything below lives here. |
| `executable reckon-server` | `app/` | A few lines: load config, build the pool, start the HTTP server. |
| `executable reckon-cli` | `cli/` | Command-line tools: `import-rbc-csv` (Phase 2). |
| `executable reckon-codegen` | `codegen/` | Writes the TypeScript types for the frontend. |
| `test-suite reckon-test` | `test/` | hspec tests against the library. |

Keeping executables thin and putting logic in the library means tests can
exercise everything the server does.

The `common shared` stanza sets the **language edition** (`GHC2024`, a bundle
of widely used extensions) plus three extensions that shape how the code
reads:

- `OverloadedStrings`: string literals can be `Text` or `ByteString`, not just
  `String`.
- `OverloadedRecordDot`: `config.port` instead of `port config`.
- `DuplicateRecordFields`: two records can both have a field called, say,
  `amountCents`.

It also turns on strict warnings. CI adds `-Werror`, so warnings can't be
merged.

---

## `app/Main.hs`: startup

```haskell
main = do
  config <- loadConfig
  databasePool <- createDatabasePool config.databaseUrl databasePoolSize
  let env = AppEnv {config, databasePool}
  ...
  runSettings settings (logStdoutDev (application env))
```

- `do` notation sequences IO actions. `x <- action` runs an action and names
  its result. `let` names a pure value.
- `AppEnv {config, databasePool}` uses **NamedFieldPuns** (part of GHC2024):
  it means `AppEnv {config = config, databasePool = databasePool}`.
- `&` is reverse function application (`x & f = f x`). It lets the Warp
  settings read top-to-bottom like a builder.
- `logStdoutDev` is **WAI middleware**: a function from `Application` to
  `Application` that logs each request. Middleware composes by function
  application.

**Q: Why is `main` so small?**
A: Executables are hard to test. Everything testable is in the library, and
`main` only wires the pieces together: config, pool, environment, server.

---

## `Reckon.Config`: configuration as a pure function

```haskell
configFromEnvironment :: [(String, String)] -> Either ConfigError Config
loadConfig :: IO Config
```

- **Pure core, effectful shell.** Parsing the configuration doesn't need IO.
  It's a function from a list of variables to either an error or a `Config`.
  Only `loadConfig` reads the real environment. So tests can call
  `configFromEnvironment [("RECKON_PORT", "eighty"), ...]` directly, without
  touching process state.
- **`Either e a`** is the standard way to return "an error of type `e` or a
  value of type `a`". Inside `configFromEnvironment`, `do` notation works in
  `Either`: the first `Left` short-circuits the rest, like an early return.
- **`ConfigError` is a sum type**, not a string. Callers (and tests) can match
  on *which* error happened. `renderConfigError` turns it into a message for
  humans at the very edge.
- `\case` (LambdaCase) is shorthand for `\x -> case x of ...`.
- `deriving stock (Show, Eq)`: GHC writes the `Show` and `Eq` instances.
  `stock` says to use GHC's built-in deriving (as opposed to `newtype` or
  `anyclass` deriving). Being explicit is a style choice enforced by
  `-Wmissing-deriving-strategies`.

**Q: Why not just call `getEnv "DATABASE_URL"`?**
A: `getEnv` throws an exception with an unhelpful message when the variable is
missing, and it mixes IO into logic that's pure. With `Either`, missing and
malformed values are ordinary data, which can be tested and turned into a
clear message.

---

## `Reckon.Database`: the pool and the ping

```haskell
createDatabasePool :: ByteString -> Int -> IO ConnectionPool
pingDatabase :: ConnectionPool -> IO DatabaseStatus
```

- A **connection pool** keeps a few Postgres connections open and lends them
  to requests. Opening a connection per request is slow. persistent's pool
  opens connections lazily, so the server starts even if Postgres isn't up yet.
- **Logging:** persistent logs every SQL statement at debug level through
  `monad-logger`. `filterLogger` keeps only warnings and errors.
  `runStdoutLoggingT` supplies the logger that the pool captures.
- **The ping** runs `SELECT 1` through the pool and turns every possible
  failure into `DatabaseUnreachable`:
  - `tryAny` (from `unliftio`) catches synchronous exceptions (connection
    refused, bad password) as a `Left`. Unlike catching `SomeException`, it
    does **not** catch asynchronous exceptions, such as the one `timeout` uses
    to cancel work, or the one Warp uses to kill a request. Swallowing those
    is a classic Haskell bug.
  - `timeout` returns `Nothing` if the action takes longer than 2 seconds.
  - The result type is `Maybe (Either SomeException [Single Int])`. A single
    `case` matches the one success shape and treats everything else as
    unreachable.
- `rawSql` runs literal SQL. `Single` is persistent's wrapper for a
  one-column row.

**Q: What's the difference between synchronous and asynchronous exceptions?**
A: A synchronous exception is thrown by the code you're running (a failed
connect). An asynchronous exception is thrown *into* your thread by someone
else (`timeout`, `killThread`). If you catch and ignore the second kind, you
break cancellation. `tryAny` and `safe-exceptions` exist to make the safe
choice the default.

---

## `Reckon.App`: the ReaderT pattern

```haskell
data AppEnv = AppEnv { config :: Config, databasePool :: ConnectionPool }
type AppM = ReaderT AppEnv Handler
runAppM :: AppEnv -> AppM a -> Handler a
```

- **`Handler`** is Servant's monad for request handlers. It can do IO and can
  fail with an HTTP error (`throwError err404`).
- **`ReaderT AppEnv Handler`** stacks a "reader" on top: inside `AppM` you can
  call `asks (.databasePool)` to get something out of the environment, without
  passing `AppEnv` as an argument everywhere. That's the **ReaderT pattern**,
  the most common way to structure Haskell web apps.
- `(.databasePool)` is a **record dot section**, a function that gets the
  field. `asks f` applies `f` to the environment.
- `runAppM env action = runReaderT action env` supplies the environment,
  turning an `AppM a` into a plain `Handler a`.
- `type AppM = ...` is a **type synonym** (just another name). A
  `newtype AppM` would be a distinct type, which is useful for custom
  instances. We'll switch if we need that (see DECISIONS D005).

**Q: What's a monad transformer?**
A: A way to add a capability to an existing monad. `ReaderT r m` takes a
monad `m` and adds "read-only access to an `r`". Here `m` is `Handler`, so
`AppM` can do everything `Handler` can, plus read `AppEnv`. `liftIO` runs
plain IO inside it.

**Q: Why not a global variable for the pool?**
A: Haskell has no mutable globals (without unsafe tricks), and even in
languages that allow them they make testing hard. With `AppEnv`, a test can
build an environment pointing at the test database, or at a dead port, as
`ServerSpec` does.

---

## `Reckon.Api`: the API is a type

```haskell
type Api = "api" :> NamedRoutes Routes

data Routes mode = Routes
  { health :: mode :- "health" :> Get '[JSON] HealthResponse }
```

- This is **type-level programming**. `"api"` and `"health"` are type-level
  strings (enabled by `DataKinds`), `:>` joins path segments, and
  `Get '[JSON] HealthResponse` says "GET, responds with JSON, body is a
  `HealthResponse`". `'[JSON]` is a type-level list of content types.
- Servant reads this type to generate the router, the JSON encoding, and
  (with other packages) clients and docs. The API description can't drift
  from the implementation, because the implementation is type-checked
  against it.
- **NamedRoutes:** `Routes` is a record whose fields are routes. The `mode`
  parameter is how one record serves several purposes. In `Routes
  (AsServerT AppM)` each field is a handler, and in a client it would be a
  client function. `mode :- route` is the type family that picks which.

**Q: What happens if a handler returns the wrong type?**
A: A compile error. The field `health` in `Routes (AsServerT AppM)` has type
`AppM HealthResponse`, so a handler returning anything else doesn't type-check.

---

## `Reckon.Api.Types` and `JsonOptions`: one definition, two languages

```haskell
data DatabaseStatus = DatabaseReachable | DatabaseUnreachable
data HealthResponse = HealthResponse { databaseStatus :: DatabaseStatus, serverVersion :: Text }

$(deriveJSONAndTypeScript (enumOptions "Database") ''DatabaseStatus)
$(deriveJSONAndTypeScript recordOptions ''HealthResponse)
```

- **Template Haskell (TH)** is compile-time code generation. `$( ... )` is a
  *splice*: the code inside runs at compile time and produces declarations.
  `''HealthResponse` (two quotes) is the *name* of the type, passed to the
  generator.
- `deriveJSONAndTypeScript` generates three things from one set of options:
  `ToJSON` and `FromJSON` instances (used by Servant to send and receive
  JSON) and a `TypeScript` instance (used by codegen). Because they share the
  options, the JSON the server sends and the TypeScript type the frontend
  compiles against can't disagree.
- **Stage restriction:** a splice can only use functions defined in *other*
  modules, since they must already be compiled when the splice runs. That's
  why `enumOptions` and `recordOptions` live in `Reckon.Api.JsonOptions`.
- `enumOptions "Database"` strips the constructor prefix and snake_cases the
  rest: `DatabaseReachable` becomes `"reachable"`. Prefixed constructor names
  keep them unique in Haskell (constructors share a namespace per module).
- `typeScriptDeclarations` collects every type's declarations for codegen.
  `Proxy @HealthResponse` is a value that carries only a type
  (`TypeApplications` syntax), which is how you pass "a type" to a function.

**Q: Why generate TypeScript instead of writing it?**
A: A hand-written type can silently drift. If the backend renames a field,
the frontend still compiles and breaks at runtime. Generated types turn that
into a compile error, and CI fails if the committed `generated.ts` is stale.

---

## `Reckon.Server`: handlers

```haskell
server :: Routes (AsServerT AppM)
server = Routes { health = getHealth }

getHealth :: AppM HealthResponse
getHealth = do
  pool <- asks (.databasePool)
  databaseStatus <- liftIO (pingDatabase pool)
  pure HealthResponse {databaseStatus, serverVersion = reckonVersion}

application :: AppEnv -> Application
application env = serve api (hoistServer api (runAppM env) server)
```

- `liftIO` runs an `IO` action (`pingDatabase`) inside `AppM`.
- `hoistServer api (runAppM env) server` converts every handler from `AppM`
  to Servant's `Handler` by applying `runAppM env`. That's a **natural
  transformation**: a function that works for any result type `a`.
- `serve` turns the server into a WAI `Application`, a plain function from
  request to response that any WAI server (Warp) or test harness (hspec-wai)
  can run.
- `reckonVersion` comes from `Paths_reckon`, a module cabal generates with
  the package's version from `reckon.cabal`.

---

## `codegen/Main.hs` and `Reckon.Api.TypeScript`

`renderTypeScriptModule` formats every declaration from
`typeScriptDeclarations` with `export` and a "do not edit" header.
`reckon-codegen OUTPUT_PATH` writes it. `scripts/codegen.sh` builds and runs
it, and with `--check` diffs against the committed file instead (CI).

The output for the health types:

```ts
export type HealthResponse = IHealthResponse;

export interface IHealthResponse {
  databaseStatus: DatabaseStatus;
  serverVersion: string;
}

export type DatabaseStatus = "reachable" | "unreachable";
```

The `I`-prefixed interface plus alias is aeson-typescript's fixed convention
for records (DECISIONS D018). Frontend code always uses the plain name.

The rendering lives in the library, not the executable, so a test can assert
on the generated TypeScript (see `TypesSpec`).

---

## The ledger (Phase 1)

Read these in order: `Money` → `Ledger.AccountType` → `Database.Schema` →
`Ledger.Entry` → `Ledger`. Then read the SQL in
`db/migrations/20260922210000_create_ledger.sql`, the second half of the story.

### `Reckon.Money`: `Cents`

```haskell
newtype Cents = Cents Int64
  deriving newtype (Eq, Ord, PersistField, PersistFieldSql)
instance Semigroup Cents where Cents a <> Cents b = Cents (a + b)
instance Monoid Cents where mempty = Cents 0
```

- A **newtype** is a wrapper with zero runtime cost. At runtime it *is* an
  `Int64`, but the type checker treats it as a different type, so you can't
  pass a row count where money is expected.
- `deriving newtype` reuses the wrapped type's instances: comparison, and
  persistent's conversion to and from a `BIGINT` column.
- **No `Num` instance, on purpose** (DECISIONS D027). Addition is `<>`, zero is
  `mempty`, and `sumCents` is `mconcat`. Summing money uses the same
  `Monoid` vocabulary as concatenating lists.

**Q: Why not `Double`?**
A: Binary floating point can't represent 0.10 exactly, so rounding errors
accumulate, and a ledger has to reconcile to the cent. Integer cents are
exact. Formatting as dollars happens only at display time.

### `Reckon.Ledger.AccountType`

A plain sum type with five constructors, a hand-written `PersistField`
instance that stores it as text (DECISIONS D028), and `naturalBalance`,
which turns the raw signed balance into what a person expects to see: a
credit card you owe $120 on is stored as −12000 and shown as 12000.

`deriving stock (Enum, Bounded)` gives `[minBound .. maxBound]`, the list of
all five, which `accountTypeFromText` and the round-trip test use.

### `Reckon.Database.Schema`: persistent entities

```haskell
share [mkPersist sqlSettings] [persistLowerCase|
JournalLine sql=journal_lines
  entryId JournalEntryId
  ledgerAccountId LedgerAccountId
  amountCents Cents
|]
```

- A **quasi-quote** (`[persistLowerCase| ... |]`) embeds a small language
  inside Haskell. Template Haskell (`mkPersist`) turns it into:
  - a record `JournalLine { journalLineEntryId, journalLineLedgerAccountId, journalLineAmountCents }`
  - a key type per table (`JournalEntryId`, `LedgerAccountId`). They're
    **different types**, so passing an entry id where an account id belongs
    is a compile error. That's the spec's "newtype per ID type", for free.
  - field constructors (`JournalLineEntryId`) used in queries.
- This module switches *off* `DuplicateRecordFields`, because persistent
  generates its own prefixed field names.
- It only *describes* tables. The SQL migration creates them (D006, D028).

### `Reckon.Ledger.Entry`: smart constructors

```haskell
newtype BalancedLines = BalancedLines [EntryLine]   -- constructor NOT exported
mkBalancedLines :: [EntryLine] -> Either EntryError BalancedLines
reverseLines   :: BalancedLines -> BalancedLines
```

This is the most important idea in Phase 1. The module exports the *type*
`BalancedLines` but not its *constructor*. The only way anyone outside can
get a `BalancedLines` is `mkBalancedLines`, which checks: at least two
lines, no zeros, sum zero. So a function that takes `BalancedLines`
(`postEntry`) never needs to re-check. The type is the proof. This pattern is
often summed up as **"parse, don't validate"**.

- `reverseLines` returns `BalancedLines`, not `Either`: negating every line of
  a balanced set is always balanced, so it can't fail, and the type says so.
- `NewJournalEntry` goes further: even its *fields* aren't exported, because
  record-update syntax (`entry { description = "" }`) would otherwise let
  code build an invalid value without going through `mkNewJournalEntry`.
- Errors are a sum type (`EntryError`), not strings, so tests and callers
  can match on exactly which rule failed.

**Q: If the database checks balance anyway, why check in Haskell too?**
A: They do different jobs. The type catches mistakes at compile time and
gives a precise error before touching the database. The trigger is the
guarantee that holds for *every* writer, including psql, a future script, or
a bug. Defense in depth.

### `Reckon.Ledger`: database operations

- Functions run in `SqlPersistT m`: "a database action inside a transaction".
  The *caller* decides where the transaction begins and ends (`runSqlPool`),
  so an entry and its lines are always saved together or not at all.
- `postReversal` returns `Either ReversalError JournalEntryId`. Reversing a
  missing entry, or one already reversed, is an expected outcome that gets
  its own error, not an exception.
- `accountBalanceAsOf` is an **esqueleto** query, type-safe SQL:

  ```haskell
  (line :& entry) <- from $ table @JournalLine `innerJoin` table @JournalEntry `on` ...
  where_ (line ^. JournalLineLedgerAccountId ==. val accountId &&. entry ^. JournalEntryOccurredOn <=. val asOf)
  pure (sum_ (line ^. JournalLineAmountCents))
  ```

  `^.` reads a column. `val` turns a Haskell value into a SQL parameter (no
  string building, so no SQL injection). Comparing a column to a value of the
  wrong type is a compile error. `SUM` over `BIGINT` comes back from Postgres
  as `NUMERIC`, hence the `Rational` and the whole-number check.

### The SQL side (the migration)

| Rule | Mechanism |
|---|---|
| ≥ 2 lines, sum = 0; reversal cancels exactly | `check_journal_entry()`, run by `CONSTRAINT TRIGGER ... DEFERRABLE INITIALLY DEFERRED`, i.e. at COMMIT |
| Append-only | `BEFORE UPDATE OR DELETE` / `BEFORE TRUNCATE` triggers that `RAISE EXCEPTION` |
| No lines added to old entries | `created_in_transaction DEFAULT txid_current()` + `BEFORE INSERT` trigger on lines |
| Reversed at most once | `UNIQUE (reverses_entry_id)` |

**Q: What's a deferred constraint trigger, and why is it needed here?**
A: A normal trigger runs right after each INSERT. But while you insert an
entry's lines one by one, the entry is *temporarily* unbalanced. A deferred
trigger waits until COMMIT, when the whole entry exists, and if it fails, the
entire transaction rolls back.

**Q: How would someone sneak a change past an append-only journal, and how is
that blocked?**
A: By *inserting* a balanced pair of new lines into an old entry. No UPDATE
is needed, and the sum stays zero. The `created_in_transaction` check rejects
lines for any entry not created in the current transaction.

---

## Importing bank exports (Phase 2)

Read in order: `Bank` → `Import.RbcCsv` → `Import.Dedupe` → `Import`, then
`cli/Main.hs`. The first three are **pure** (no database, no IO), which is
why most of Phase 2's tests need no database at all.

### `Reckon.Bank`: `Last4`

The same smart-constructor idea as `BalancedLines`, applied to privacy.
`Last4`'s constructor is hidden, and `mkLast4` accepts exactly four digits,
so a value of type `Last4` *cannot* hold a full account number.
`last4FromAccountNumber` is the only door in from a raw account number, and
it throws everything but the last four digits away.

**Q: How do you guarantee you never store a full account number?**
A: Four layers. The type can't hold more than four digits. The parser
converts at the boundary, so the full number never gets past it. The column
has a CHECK constraint. And a test imports a file and scans every stored
column (as JSON) for the full number.

### `Reckon.Import.RbcCsv`: parsing

- `parseRbcCsv :: ByteString -> Either [CsvError] [RbcRow]`. `Either` with a
  *list* of errors: parsing doesn't stop at the first bad row, so the user
  sees every problem at once. `partitionEithers` splits the per-row results
  into failures and successes.
- **cassava** does the CSV mechanics (quotes, commas inside quotes, CRLF).
  The code maps columns by *header name*, so the parser doesn't depend on
  column order.
- `parseCents` turns `"-4.50"` into `Cents (-450)` by splitting on the dot
  and working with digit strings. There is no `read :: Double` anywhere,
  because a float would bring back the rounding error `Cents` exists to
  avoid.
- `let problem :: Text -> Either CsvError a` needs a type signature. GHC2024
  turns on `MonoLocalBinds`, which stops local definitions that use outer
  variables (here `line`) from being generalized. The signature makes
  `problem` usable at every result type.

### `Reckon.Import.Dedupe`: the dedupe logic

The core of Phase 2 (DECISIONS D029, D030).

```haskell
assignOccurrences :: [IncomingRow payload] -> [(RowKey, IncomingRow payload)]
planImport :: [StoredRow storedId] -> [IncomingRow payload] -> ImportPlan storedId payload
```

- **`assignOccurrences`** is a left fold carrying a `Map (Day, Fingerprint) Int`
  of how many of each row it has seen so far. The second identical coffee gets
  occurrence 2.
- **`planImport`** is set arithmetic. `rowsToAdd` are incoming keys not in the
  stored set. *Absent* rows are stored keys not in the incoming set. Absent
  rows are then paired with added rows of the same amount on the same day
  (`PossibleDuplicate`), and whatever is left on an interior day becomes
  `MissingFromNewerExport`.
- **Type parameters instead of concrete types:** `StoredRow storedId` and
  `IncomingRow payload` don't care what the id or payload is. In production,
  `storedId` is a database key (`RawBankRowId`) and `payload` is the parsed CSV
  row. In tests they're `Int` and `()`. This is **parametric polymorphism**:
  the planner *can't* depend on database details, because it doesn't know
  what the type is. The same function runs in both places.

**Q: Walk me through two identical coffees in overlapping exports.**
A: Export 1 has two rows with the same date and fingerprint. They get
occurrences 1 and 2, and both keys are stored. Export 2 has the same two
rows, which get the same two keys, so `rowsToAdd` is empty. If export 1 was
taken mid-day and caught only one, it stored key #1. Export 2's key #2 is new
and gets added. Nothing depends on row order, only on how many identical rows
there are.

**Q: What if the bank changes a description between exports?**
A: The fingerprint changes, so the new version looks like a new row and gets
added. The old version is now absent from a day the new export covers. The
planner sees an absent row and an added row with the same amount on the same
day, and flags them as a `possible_duplicate` for a person to resolve. It
never guesses, and never deletes.

### `Reckon.Import`: the database side

`importRbcCsv` runs in one transaction (the caller's `runSqlPool`):

1. SHA-256 the bytes (`cryptohash-sha256`). If `import_batches` already has
   that hash, return `AlreadyImported`.
2. Parse. On failure, return the errors. Nothing has been written.
3. Insert the batch. Then, per account: find or register the bank account;
   **`SELECT ... FOR UPDATE`** its row, so a concurrent import of the same
   account waits; load stored rows in the file's date range; run
   `planImport`; insert rows, review items and coverage.

`rawSql` returns rows (it's used for the lock, which returns the id).
`rawExecute` is for statements that return nothing. persistent refuses to run
a row-returning `SELECT` through `rawExecute`, which was a real bug caught by
the tests.

**Q: What stops two simultaneous imports from both adding the same row?**
A: The row lock makes the second one wait, and then plan against what the
first committed. Even without the lock, the UNIQUE dedupe key would reject a
duplicate insert and roll the second transaction back.

### `cli/Main.hs`

`reckon-cli import-rbc-csv FILE`: load config, make a one-connection pool,
read the file, run `importRbcCsv` in one transaction, print
`renderImportOutcome`. `make import file=...` builds and runs it
(`scripts/import.sh`).

---

## Tests

`backend/test/Main.hs` runs every spec with **hspec**, a BDD-style framework
(`describe`, `it`, `shouldBe`).

| Spec | What it proves |
|---|---|
| `ConfigSpec` | Config parsing: defaults, missing and invalid values. Pure, no IO. |
| `TypesSpec` | The exact JSON wire format of `HealthResponse`, a round-trip for every constructor, and that the generated TypeScript uses the same names and strings. |
| `ServerSpec` | The real `Application` over HTTP (via **hspec-wai**, no network): 200 plus reachable against the test DB, 200 plus unreachable against a dead port, 404 for unknown routes. |

`TestSupport.makeTestEnv` connects to `TEST_DATABASE_URL` and fails loudly if
it isn't set (DECISIONS D011).

`ServerSpec` has a custom matcher, `jsonBodyIs`. Instead of comparing raw
bytes, it decodes the response body back into a `HealthResponse` and
compares values, so a failure prints two readable Haskell values rather than
two byte strings. `MatchBody` is just a function `headers -> body -> Maybe
errorMessage`, where `Nothing` means "matched". That's a common Haskell
pattern: a validator returns `Maybe` the problem.

**Q: How do you test the "database is down" path without stopping Postgres?**
A: Build an `AppEnv` whose pool points at port 1, where nothing listens. The
pool connects lazily, so the environment builds fine, and the first query
fails like it would in production. Because the environment is a plain value,
the fault can be injected without mocks.

Phase 1 adds:

| Spec | What it proves |
|---|---|
| `Ledger.EntrySpec` | Pure rules, mostly as **hedgehog properties**: any generated zero-sum set is accepted; skewing it by *x* is rejected with `LinesDoNotBalance x`; reversing negates every line and still balances. Plus `naturalBalance` and account-type round-trips. |
| `LedgerSpec` | Against the real test database: balances as of a date, reversals restoring balances, double and missing reversals rejected. **Raw-SQL tests** that bypass Haskell to show the database rejects unbalanced entries, single-line and empty entries, UPDATE/DELETE, lines added to an old entry, and a reversal that doesn't cancel. And the **model-based property** below. |

**Property-based testing** (hedgehog): instead of hand-picking examples, you
write a *generator* of random inputs and a *property* that must hold for all
of them. Hedgehog runs it 100 times, and when it finds a failure it
*shrinks* the input to the smallest case that still fails.

The main property, `ledgerMatchesModel`:

1. Generate a random scenario: 1 to 25 operations, each either "post an entry of 2
   to 6 random lines over 4 accounts" or "reverse some earlier entry", on random
   dates.
2. Run it against the **real database**, one transaction per operation, just
   like production.
3. Keep a trivially correct **model** alongside: a list of (date, account,
   amount).
4. Check that each account's balance (at a random date and at the far future)
   equals the model's, that all balances sum to zero, and that every stored
   entry has at least two lines summing to zero.

This is **model-based testing**: the real system (SQL, triggers, esqueleto)
is compared against a model simple enough to be obviously right. To confirm
the test has teeth, a planted bug (`<` instead of `<=` in the as-of filter)
was introduced, the property failed, and the bug was reverted.

Phase 2 adds:

| Spec | What it proves |
|---|---|
| `Import.RbcCsvSpec` | The parser on the fixtures: fields, quoted commas, **only the last 4 digits survive**, BOM/CRLF/blank lines, columns found by name, every bad row reported by line number. `parseCents` exactness, including a **round-trip property** over random amounts. |
| `Import.DedupeSpec` | Fingerprint normalization, occurrence numbering, each planning rule by example, and the main **property**: a random true history (full of identical same-day rows), cut into overlapping exports shuffled within each day, some with a partial last day, imported in random order. The result is exactly the true history, with no review flags, and re-importing everything changes nothing. Planting a bug (all occurrences = 1) makes it fail. |
| `ImportSpec` | Against the database: first import registers the account; the same file twice is a no-op; the overlapping fixture gives exactly 5 added, 4 present, 1 possible duplicate, 1 missing, with the right rows linked; a malformed file saves nothing. Raw SQL: a duplicate key is rejected, evidence can't be updated or deleted, and no stored column contains the full account number. |

The dedupe property is worth being able to explain. It describes the whole
problem ("whatever the bank gives me, as long as it's truthful, I end up
with exactly the real transactions") and checks it against thousands of
generated scenarios, including ones nobody would think to write by hand.

Tests never delete anything (the journal forbids it). Each test makes its
own accounts with a unique suffix, and `make test` recreates the test
database on each run (DECISIONS D026).

---

## Frontend

| File | Role |
|---|---|
| `src/main.tsx` | Mounts React and provides a TanStack Query `QueryClient` (the cache for server data) |
| `src/App.tsx` | Page layout |
| `src/api/generated.ts` | **Generated** API types. Never edited by hand. |
| `src/api/client.ts` | `api.getHealth()` etc.: typed `fetch` wrappers, and `ApiError` for non-2xx responses |
| `src/components/HealthBadge.tsx` | `useQuery` polls `/api/health` every 10 s and shows one of four states |

Worth pointing out in `HealthBadge`:

```ts
switch (status) {
  case 'reachable': ...
  case 'unreachable': ...
  default: return status satisfies never
}
```

`DatabaseStatus` is the generated union `"reachable" | "unreachable"`. In the
`default` branch TypeScript has narrowed `status` to `never`. If the backend
adds a third status and the types are regenerated, `status` is no longer
`never` there, and the build fails until the new case is handled. That's
exhaustiveness checking across the language boundary.

---

## Glossary

| Term | Meaning |
|---|---|
| **Monad** | A type that supports sequencing with `do` notation (`IO`, `Either e`, `Maybe`, `AppM`). |
| **Monad transformer** | Adds a capability to another monad (`ReaderT r m` adds read-only access to `r`). |
| **Type class** | An interface (`ToJSON`, `Eq`). An *instance* is an implementation for a type. |
| **newtype** | A wrapper type with zero runtime cost, used to make distinct types (e.g. `Cents` vs `Int64`). |
| **Sum type** | "One of these" (`DatabaseReachable \| DatabaseUnreachable`). Pattern matching must handle every case. |
| **Template Haskell** | Compile-time code generation (`$( ... )` splices). |
| **DataKinds** | Lets values (strings, lists) appear in types, which is how Servant describes paths. |
| **WAI** | Web Application Interface: `Application = Request -> (Response -> IO) -> IO`. The common interface between Haskell web servers and frameworks. |
| **Warp** | The HTTP server that runs a WAI `Application`. |
| **persistent** | Database library: connection pools, typed entities, and queries (with **esqueleto** for SQL joins, from Phase 1). |
| **Smart constructor** | A function that validates input before building a value, where the raw constructor is hidden, so every value of the type is valid. |
| **Property-based test** | A test that checks a rule over many randomly generated inputs, shrinking any failure to a minimal example. |
| **Fingerprint** | The normalized description + cheque number + amount that identifies "the same transaction" on a given day. |
| **Occurrence** | The position of a row among identical rows (same date and fingerprint) in one file: 1, 2, 3, ... |
| **Parametric polymorphism** | A function that works for any type in a type variable (`StoredRow storedId`) and so can't depend on what that type is. |
| **Double-entry** | Every transaction is recorded as lines that sum to zero: whatever one account gains, others lose. |
