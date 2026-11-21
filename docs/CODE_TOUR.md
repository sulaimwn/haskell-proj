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
- [Posting and reconciliation (Phase 3)](#posting-and-reconciliation-phase-3)
- [Shared expenses (Phase 4)](#shared-expenses-phase-4)
- [Reading screenshots with Claude (Phase 5)](#reading-screenshots-with-claude-phase-5)
- [The rule language (Phase 7)](#the-rule-language-phase-7)
- [Scheduled jobs and reminders (Phase 7)](#scheduled-jobs-and-reminders-phase-7)
- [The HTTP API and the screens (Phase 6)](#the-http-api-and-the-screens-phase-6)
- [The frontend (Phase 6)](#the-frontend-phase-6)
- [Tests](#tests)
- [Glossary](#glossary)

---

## The shape of the backend

`backend/reckon.cabal` defines five **components** that share one library:

| Component | Directory | What it is |
|---|---|---|
| `library` | `src/` | All the real code. Everything below lives here. |
| `executable reckon-server` | `app/` | A few lines: load config, build the pool, start the HTTP server. |
| `executable reckon-cli` | `cli/` | Command-line tools: `import-rbc-csv` (Phase 2), `post`, `post-row`, `add-rule`, `opening-balance`, `checkpoint`, `reconcile` (Phase 3); `add-person`, `split-row`, `recategorize`, `owed`, `spending` (Phase 4); `import-screenshots`, `provisional`, `release-provisional`, `eval-screenshots` (Phase 5); `rules`, `check-rule`, `apply-rule`, `delete-rule` and the rule-language form of `add-rule`, `run-checks`, `reminders`, `add-due-date`, `due-dates`, `delete-due-date` (Phase 7). |
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
  screenshotReading <- loadAnthropicConfig >>= \case ...   -- ReadingAvailable | ReadingUnavailable
  let env = AppEnv {config, databasePool, screenshotReading}
      settings = defaultSettings & setHost (fromString config.host) & setPort config.port
  runSettings settings (logStdout (application env))
```

- `do` notation sequences IO actions. `x <- action` runs an action and names
  its result. `let` names a pure value.
- `AppEnv {config, databasePool}` uses **NamedFieldPuns** (part of GHC2024):
  it means `AppEnv {config = config, databasePool = databasePool}`.
- `&` is reverse function application (`x & f = f x`). It lets the Warp
  settings read top-to-bottom like a builder.
- `logStdout` is **WAI middleware**: a function from `Application` to
  `Application` that logs each request (method, path, status). Middleware composes by function
  application. It is deliberately not `logStdoutDev`, which also prints small request bodies: a
  small CSV upload would land in the terminal (D066).
- `setHost (fromString config.host)` is what keeps the API on loopback (D061). Without it Warp
  listens on every interface.
- Whether screenshots can be read is decided here, once: with `ANTHROPIC_API_KEY` set the
  extractor is built and handed to the handlers inside `AppEnv`; without it they get a reason.

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
- `Config` also carries `host` (`RECKON_HOST`, default `127.0.0.1`) and `allowedHosts` (a comma list,
  default `localhost,127.0.0.1,[::1]`). Safe defaults live in the pure parser, and `ConfigSpec` tests
  the default, a list with stray spaces and commas, and an empty value (D061).
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
server = Routes { health = getHealth, accounts = \asOf -> asOfOrToday asOf >>= runDb . Views.accountSummaries, ... }

application :: AppEnv -> Application
application env =
  hostGuard env.config.allowedHosts
    (jsonOnlyWrites (serve api (hoistServer api (runAppM env) server)))
```

- `liftIO` runs an `IO` action inside `AppM`. `runDb` is `asks (.databasePool)` plus `runSqlPool`.
- `hoistServer api (runAppM env) server` converts every handler from `AppM`
  to Servant's `Handler` by applying `runAppM env`. That's a **natural
  transformation**: a function that works for any result type `a`.
- `serve` turns the server into a WAI `Application`, a plain function from
  request to response that any WAI server (Warp) or test harness can run.
  `hostGuard` and `jsonOnlyWrites` are WAI `Middleware` (`Application -> Application`)
  wrapped around it, so they run before Servant sees the request. See
  [the HTTP API and the screens](#the-http-api-and-the-screens-phase-6).
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
(`scripts/import.sh`). Phase 3 adds more commands; see below.

---

## Posting and reconciliation (Phase 3)

Read in order: `Posting.Classify` → `Posting` → `Reconcile.Explain` →
`Reconcile`, then the new commands in `cli/Main.hs`. Same split as Phase 2:
the two modules that make decisions are **pure**, and the two that touch
the database only load, call the pure function, and write.

### `Reckon.Posting.Classify`: what is each row?

```haskell
planPosting ::
  (Ord rowId, Eq account) =>
  WellKnownAccounts account -> [Rule account] -> [EvidenceRow rowId account] -> PostingPlan rowId account
```

Input: every unposted row, plus rows already posted on a guess (marked
`alreadyPosted`). Output: a `PostingPlan` with one `PlannedPosting` per row
to post (its `Classification` and counter account) and the rows
`leftForReview` with a `ReviewReason`.

The steps, in order:

1. Zero-amount rows → review (a journal line can't be zero).
2. **Cancellation pairs** (`isCancellationPair`): same account, opposite
   amounts, within 45 days, one mentions CANCEL/REVERS/RETURN/DECLIN/REFUND.
3. **Transfer pairs** (`isTransferPair`) among what's left: different
   accounts, opposite amounts, within 5 days.
4. Every other row on its own (`classifySingle`): the first matching rule,
   else `looksLikeCardPayment`, else uncategorized by sign.

Ideas worth pointing at:

- **`pairUniquely`** takes the pairing rule as a function argument
  (`EvidenceRow -> EvidenceRow -> Bool`), so steps 2 and 3 share it. It
  builds a `Map` from each row to its candidates, and accepts a pair only
  when it is **mutual**: each row's one and only candidate is the other.
  Everything with candidates but no mutual pair is returned as ambiguous.
  One function, two relations: that's what higher-order functions are for.
- **The same parametric-polymorphism trick as `planImport`:** `rowId` and
  `account` are type variables. In production they're `RawBankRowId` and
  `LedgerAccountId`; in `ClassifySpec` they're `Int` and `Text`, so a test
  can compare a counter account with the plain string `"asset:clearing"`.
- **`Classification` is a sum type**, and `CancelledPairWith rowId` and
  `TransferWith rowId` carry the partner's id. The summary counts and the
  tests pattern-match on it, so adding a new kind of row is a compile error
  everywhere it isn't handled (with the warnings on).
- **Guesses are data, not special cases.** An already-posted row
  participates in pairing like any other. A pair where one side is
  `alreadyPosted` produces a posting with `replacesExistingEntry = True`;
  a pair of two already-posted rows produces nothing.

**Q: Why not just pair a −$200 with the nearest +$200?**
A: Because a wrong pairing is silent and a missing one is loud. If a
transfer has two possible matches, picking one could hide a real refund as a
transfer, and nobody would notice. Leaving all three rows unposted makes the
reconciliation report point straight at them. The rule "each is the other's
only candidate" is the simplest one that never guesses.

**Q: Why check cancellations before transfers?**
A: "Cancelled" in a description is stronger evidence than an amount
matching in another account. An e-Transfer sent and cancelled is −$30 then
+$30 in the same account. If a +$30 also appeared on a card that week,
transfer pairing alone would see an ambiguity. Taking the cancellation
first removes both rows before transfers are considered.

### `Reckon.Posting`: the database side

`postPendingRows` is short because the decisions are elsewhere:

1. `wellKnownAccounts` finds or creates `asset:clearing`,
   `liability:untracked-cards`, `expense:uncategorized`,
   `income:uncategorized`. `WellKnownAccounts` is built with `<$>` and
   `<*>`: four actions in the database monad, combined into one record
   (**applicative style**).
2. Load the unposted rows, and the repairable ones (posted on a guess, dated
   within 45 days before the earliest unposted row).
3. `planPosting`.
4. For each planned posting: if it replaces a guess, `postReversal` the old
   entry **on its original date**, then `postRow`.

`postRow` builds two `EntryLine`s, passes them through the same smart
constructors as any other entry (`mkBalancedLines`, `mkNewJournalEntry`),
posts, and inserts the `JournalEntryEvidence` link. The `error` branch is
unreachable (the lines negate each other and zero rows never get here), and
the comment says why.

"Unposted" isn't a column. It's a query: *no evidence link to an entry that
hasn't been reversed*. These `NOT EXISTS` queries use `rawSql`, because
they're clearer in SQL than in esqueleto, and the columns come back as a
tuple of `Single` values that `toEvidenceRow` turns into a record.

`postRowManually` (the `post-row` command) and `addCategorizationRule`
return `Either` a small error type, and `cli/Main.hs` turns each error into a
sentence. The library never prints.

**Q: What happens if you run `make post` twice?**
A: The second run loads no unposted rows, so it plans nothing and writes
nothing. There's a test that compares the entry count before and after.

**Q: The Visa export arrives a week after the chequing one. What happens to
the payment already posted as "untracked card"?**
A: It's loaded as a repairable row. The new Visa row's only candidate is
it, and vice versa, so they pair. The old entry is reversed with the same
date it had, which is why the chequing balance on every date is unchanged,
and the row is re-posted against clearing. Nothing is edited. A test checks
the balance before and after, and dating the reversal a day late makes it
fail (it was tried).

### `Reckon.Reconcile.Explain`: why don't the numbers match?

```haskell
explainReconciliation :: ReconciliationInputs -> [Finding]
coverageGaps :: Day -> Day -> [(Day, Day)] -> [(Day, Day)]
```

Pure. `ReconciliationInputs` has everything the database knows about one
account on one date (both balances, unposted rows, possible duplicates, the
opening balance date, the date ranges imports covered). The result is a
list of `Finding`s, a sum type with one constructor per cause.

- A zero difference returns `[Reconciled]` and nothing else.
- Otherwise each check is a **list comprehension with a guard**:
  `[NoOpeningBalance difference | inputs.openingBalanceDate == Nothing]` is
  either a one-element list or empty. `concat` joins them. It reads like
  the list of rules it is.
- If nothing applies: `[Unexplained difference]`. The report never goes
  quiet about a gap.
- `coverageGaps` walks the covered ranges sorted by start date, carrying the
  first day not yet covered, and emits each gap as it passes it. There's a
  property test: no day is both in a gap and covered, and no uncovered day is
  missing from the gaps.

### `Reckon.Reconcile`: opening balances, checkpoints, reports

- `recordOpeningBalance` refuses a date on or after the account's first
  imported transaction (that transaction would be counted twice) and a zero
  amount. Recording a second one **reverses** the first; the table keeps
  both, and the current one is the one whose entry isn't reversed.
- **Signs at the edge.** You type what the statement shows: money in
  chequing, or money *owed* on a card. `naturalBalance` (from Phase 1)
  converts to raw debits and credits on the way in, and back on the way
  out. So owing $250 on the Visa is stored as −25000 on a liability, and
  there's a test for exactly that.
- `recordCheckpoint` stores a statement balance (append-only, one per
  account and date). `reconcileAccount` gathers the `ReconciliationInputs`
  and calls `explainReconciliation`. `reconcileAllCheckpoints` does it for
  every checkpoint, oldest first.

**Q: What's the reconciliation identity, and why does it hold?**
A: For every bank account and date: ledger balance = opening balance + sum
of posted rows up to that date. It holds because every entry that touches a
bank's ledger account is either the opening balance or the entry for
exactly one of its rows, with the row's amount on that date, and re-posting
reverses on the original date. The database tests check it on every day of
the fixture, and a hedgehog property checks it for random exports. It's why
the report can always find the cause: any gap must be in the evidence
(unposted rows, a missing opening balance, a duplicate, or days nobody
imported).

**Q: Why a clearing account instead of one entry per transfer?**
A: One entry has one date. A card payment leaves chequing on Feb 3 and
lands on Feb 5, so with one entry, one of the two accounts disagrees with
its own statement for two days. Two entries through `asset:clearing` keep
both accounts right on every date, and clearing's balance is literally the
money in transit. It's the standard "suspense account" technique, and
DECISIONS D040 records the change from the spec.

### The new CLI commands

`cli/Main.hs` matches on the argument list (`["post-row", rowIdText,
accountName] -> ...`), parses at the edge (`readMaybe`, `iso8601ParseM`,
`parseCents`, `mkLast4`), and runs one transaction per command. `runOrDie`
takes a transaction returning `Either Text Text`: print the message, or
print the error and exit non-zero. `scripts/reckon.sh` builds and runs the
CLI against the dev database, so every command is
`scripts/reckon.sh COMMAND ...`.

---

## Shared expenses (Phase 4)

Read in order: `Posting.Split` (pure) → `People` → `Posting` (the new
`repostRow`) → `Sharing` → `Report`. Again the rules are pure and the
database modules only look things up and write.

### `Reckon.Posting.Split`: a smart constructor for splits

```haskell
mkSplit    :: Cents -> [(Text, Cents)] -> Either SplitError Split
equalSplit :: Cents -> [Text] -> Either SplitError Split
splitParts :: Split -> [(Participant, Cents)]
```

This is the third use of the smart-constructor idea (after `BalancedLines`
and `Last4`): `Split`'s constructor isn't exported, so **a `Split` can't be
invalid**. The one trick: *my share isn't an input*. You pass what each
friend owes, and `mkSplit` computes mine as the remainder. So the parts add
up to the payment by construction, and the "my share + friends' shares ≠
total" bug can't be written.

- `data Participant = Me | Friend Text` is a sum type instead of a
  `Maybe Text` ("Nothing means me"), so the code that maps parts to accounts
  must say what it does for each case.
- `equalShares` uses `divMod`: `base` is the integer quotient, and the first
  `extra` pieces get one more cent. The properties: the pieces add up to the
  whole, differ by at most a cent, and never increase.
- The guards in `mkSplit` use **pattern guards**
  (`| Just (name, _) <- find ((<= mempty) . snd) shares = ...`): a guard that
  both tests and binds, so the error carries the offending name.

**Q: Why is my share the remainder instead of a field the user fills in?**
A: Because then it can't disagree with the rest. If both were inputs, the
function would need an "amounts don't add up" error, and every caller would
have to handle it. With the remainder, the only thing that can go wrong is
that friends' shares *exceed* the payment, which is a real mistake
(`SharesExceedAmount`), not a bookkeeping inconsistency.

**Q: Who gets the odd cent when $100.01 is split four ways?**
A: Me, first, then the friends in the order given: 25.01, 25.00, 25.00,
25.00. The person who paid absorbs the rounding. It's deterministic, tested,
and written down in DECISIONS D049.

### `Reckon.People`

`addPerson` normalizes the match text exactly as descriptions are
(`normalizeDescription`: upper case, single spaces), so "alex  smith" and
"ALEX SMITH" are the same text, and creates `receivable:<name>` with
`findOrCreateLedgerAccount`. It returns `Either PersonError PersonId`, with
one constructor per way it can be refused. `isValidPersonName` is a total
function over `Text.uncons` (no partial `head`).

`whoOwesWhat` is a `forM` over people calling `accountBalanceAsOf`.
`loadKnownPeople` turns database rows into the planner's `KnownPerson`
(the planner doesn't know the database exists).

### `Reckon.Posting`: `repostRow`

Phase 3 could only post a row once, or fix a *guess* when its pair arrived.
Phase 4 generalizes that into one function:

```haskell
repostRow :: EvidenceRow RawBankRowId LedgerAccountId -> [(LedgerAccountId, Cents)] -> SqlPersistT m (Either RepostError ())
```

"Reverse the row's entry in effect (dated like the original), post a new
one made of the bank line plus these counter lines." `recategorize` is
`repostRow` with one counter line, `split-row` is `repostRow` with several.
Three things to notice:

1. **Validate, then write.** The new entry is built (`buildEntry`, pure) and
   the pair check run *before* anything is written. A `case` on
   `buildEntry row counterLines` with `_ | partOfPair -> ...` alternatives
   handles every refusal first. So a refused request leaves no trace, and a
   test compares the journal's entry count before and after.
2. **Errors are values.** `RepostError` → `ManualPostingError` with
   `manualErrorFromRepost`, and the CLI turns each into a sentence. There is
   no `error` call on any path a user can reach.
3. **`first` from `Data.Bifunctor`** maps over the *Left* of an `Either`
   (`first manualErrorFromRepost <$> repostRow ...`), where `fmap` would
   map over the Right.

**Q: Why refuse to split a transfer leg instead of just doing it?**
A: A transfer is two entries through `asset:clearing` that net to zero.
Replacing one leg with a split would leave the clearing account holding half
the transfer forever, and the reconciliation report would be wrong in a way
that's hard to trace. The refusal says why.

### `Reckon.Sharing`

`splitRow` resolves everything first (the row, the category's account type,
each friend), plans the split purely, *then* creates the category account,
and only then calls `repostRow`. Two small idioms:

- `traverse (\name -> (name,) <$> findPersonByName name) names` uses a **tuple
  section** to keep each name next to its lookup result, so the error can
  name the first unknown person.
- The counter lines are built with a list comprehension that has a
  **pattern in the generator**: `Just account <- [accountFor participant]`
  drops any participant with no account (impossible after the checks above,
  but the type doesn't need to know that).

### `Reckon.Report`

One query: sum `journal_lines` on `expense` accounts between two dates,
grouped by account. The interesting part is what *isn't* there: no filter
for splits, transfers or reversals. Friends' shares are in receivables,
transfers in clearing, and reversals cancel arithmetically, so the account
structure makes "my share only" true by itself.

### Repayments in the planner

`Classify.planPosting` gained a `[KnownPerson account]` argument. Money in
whose description contains a person's match text, in a non-card account, and
with no rule claiming it, becomes `PossibleRepayment [names]` in
`leftForReview` instead of a posting. `partitionEithers` splits the single
rows into "needs review" (`Left`) and "post it" (`Right`) in one pass.

**Q: Why not apply a repayment automatically when only one person matches?**
A: Because it's a guess, and a wrong guess is invisible: Alex e-Transfers me
$30 for concert tickets, it silently reduces his dinner debt, and both
balances are off with nothing to flag it. Suggesting costs the user one
command. DECISIONS D050 explains and says how to flip it.

---

## Reading screenshots with Claude (Phase 5)

Read in order: `Screenshot.Extraction` → `Screenshot.Align` → `Screenshot.Match` →
`Anthropic` → `Screenshot.Store` → `Screenshot.Import`. The first three (and
`Screenshot.Score`) are **pure**; `Anthropic` has a pure core and a thin IO layer;
`Store` and `Import` are the database and orchestration.

### `Reckon.Screenshot.Extraction`: trust nothing the model says

Two halves. **What we ask:** `extractionSchema` (a JSON Schema built with aeson's `object`
and `.=`) and `extractionInstructions` (the prompt). **What we accept:**

```haskell
parseExtraction :: Day -> ByteString -> Either [ExtractionError] ExtractedScreenshot
```

- The model's reply goes through aeson twice: first into a plain `RawRow` (all text and
  booleans, using `withObject` and `.:`), then each row is *checked* into an `ExtractedRow`
  (a real `Day`, exact `Cents`, a `Section`). `onlyKeys` rejects any field the schema doesn't
  have, so a reply can't smuggle extra data in.
- **Errors are collected, not short-circuited.** Rows are checked with `either (Left . BadRow
  index) Right`, and `partitionEithers` splits failures from successes, so the user sees every
  bad row at once. (Same idea as the CSV parser.)
- `checkRow` is a `do` block in `Either RowProblem`: each line either continues or aborts the
  row with a specific `RowProblem`. `when (Text.null description) (Left EmptyDescription)` is
  the idiom for "fail unless".
- `inferDate` is one line of real logic: `find (<= takenOn)` over the same month and day in the
  years counting back from the screenshot's, using `fromGregorianValid` so 30 February simply
  isn't a candidate and 29 February is found in the last leap year. A hedgehog property checks
  it against its definition for thousands of random screenshot days.
- `parseDisplayedAmount` reuses the CSV's `parseCents`, after stripping `$`, commas, `CAD`,
  Unicode minus and brackets. There is still no floating point anywhere.

**Q: Why not ask the model for the year, or for the amount as a number?**
A: Because it would sometimes be wrong, and wrong *confidently*. The year is a rule ("the most
recent date that isn't in the future") that code applies the same way every time. A number
could arrive as `12.340000000000001`. Amounts as text, parsed by the same code as the CSV, mean
a screenshot row and a CSV row of the same transaction are exactly equal.

**Q: What happens if the model returns garbage?**
A: The whole reply is rejected with every problem listed, nothing is stored or posted, and the
image isn't recorded, so the same command can simply be run again. That's tested with a fixture
that has one of each kind of bad row.

### `Reckon.Screenshot.Align`: joining a scroll

```haskell
alignScreenshots :: (Eq identity) => (row -> identity) -> [[row]] -> Alignment row
```

Generic in the row type: the tests use `Char`s, production uses `(uploadId, ExtractedRow)` so
the database knows which upload each row came from. A left `foldl` carries what's been joined
so far; for each next screenshot, `overlapLengths` lists every `k` where the last `k` joined
rows equal the first `k` of the next. One `k`: join. Several: take the largest and warn.
None: try the reverse (wrong order), else warn and concatenate.

**Q: Why not just deduplicate rows?**
A: Because two $4.50 coffees on one day are two transactions. Deduplicating by content would
silently delete one. Aligning by *position* (the overlap is a run at the end of one list and the
start of the next) keeps both, and it's only ambiguous when the whole overlap is made of identical
rows, which is reported.

### `Reckon.Screenshot.Match`: which row is which

`planMatches :: [Provisional p] -> [Later l] -> [Match p l]`. Two stages (same amount; then a
pending hold that posted for a different amount), each built from `matchGroups`:

- Rows alike in date, words and amount are grouped (`groupAlike` with a `Map`). Groups are
  matched when each is the other's only candidate (the same rule as transfer pairing), then
  their members pair off in order.
- `descriptionsAgree` is deliberately loose (a shared word that isn't PURCHASE or PAYMENT),
  because it only decides together with amount, dates and uniqueness. It's the weakest
  heuristic in the phase, and says so (DECISIONS D057).

### `Reckon.Anthropic`: a small client

- **`ApiKey`** is a newtype with a hand-written `Show` that prints `ApiKey <redacted>`. Anything
  that contains it (including `AnthropicConfig`, which derives `Show`) therefore can't leak it.
- **`buildRequestBody :: Text -> ImageInput -> Value`** and **`readResponse :: Value -> Either
  ClientError ByteString`** are pure and tested. `readResponse` handles `stop_reason`:
  `refusal` and `max_tokens` are errors, thinking blocks are ignored, text blocks are joined.
- **`type Extractor = ImageInput -> IO (Either ClientError ByteString)`** is the seam: the real
  one is `anthropicExtractor config`, and tests use any function of that type. Dependency
  injection with no framework: a function argument.
- `sendOnce` uses `try` and shows only an exception's *content* (`HttpExceptionRequest _
  content`), because the whole exception includes the request, headers and all.
- Retries are a small recursive function over a counter, with a doubling pause.

**Q: How do you test code that calls an external API without calling it?**
A: Three layers. The pure request and response code is tested directly. The IO function is
tested against a stub server run in-process with `testWithApplication` that records requests
(headers, body) and returns canned replies, including 429s and errors. Everything above the
`Extractor` seam is tested with a scripted fake. No test needs a key or a network.

### `Reckon.Screenshot.Store`: provisional entries and their resolutions

`storeScreenshots` runs in the caller's transaction and does, in order: insert uploads; join the
screenshots; number identical rows with `assignOccurrences` (from the CSV dedupe); skip rows
already stored; resolve rows the CSV already has; reverse older pending holds that these rows
replace; post what's left as provisional entries.

`confirmProvisionalRows` is called first by `postPendingRows`. It builds a `Map` from bank
account to its open provisional rows (`Map.fromListWith (flip (<>))` keeps order), matches each
with that account's unposted CSV rows, and for each match reverses the entry and records a
resolution.

**Q: Why reverse a provisional entry instead of just editing it to the real amount?**
A: The journal is append-only. A reversal dated like the original makes the account's balance on
every date exactly what it would have been had the provisional entry never existed, and the
CSV row then lands on its own date. The history shows what was believed, and when.

### `Reckon.Screenshot.Import` and the CLI

`importScreenshots` is an `ExceptT ImportScreenshotsError IO`: `throwError` for each way to
stop, `ExceptT (either ... <$> action)` to lift an `IO (Either e a)` in. The order is the point:
cheap, offline checks first (account, image type, hash), then the costly model calls, then one
database transaction. `renderImportScreenshotsOutcome` turns the result into the text the
command prints, including a warning per alignment problem.

`scripts/reckon.sh import-screenshots LAST4 [--taken DATE] FILE...`, `provisional`,
`release-provisional ID` and `eval-screenshots DIR` are the new commands.

---

## The rule language (Phase 7)

Design: D067-D069. Rules were "description contains TEXT"; now a rule is a line of a tiny language, with
errors that say where, a preview against existing rows, and an explicit way to apply it to the past.

### `Reckon.Rules.Language`: a parser, a renderer, and errors with positions

```haskell
data Rule = Rule { conditions :: NonEmpty Condition, action :: Action }
parseRule  :: Text -> Either RuleProblem Rule
renderRule :: Rule -> Text
```

- **`NonEmpty Condition`** makes "a rule with no conditions" unrepresentable: it would match every row.
  The parser builds it with `(:|) <$> condition <*> many (keyword "and" *> condition)`.
- **megaparsec** (`Parsec Void Text`). `lexeme` / `symbol` (from `Text.Megaparsec.Char.Lexer`) wrap a
  parser so it also eats trailing whitespace, so no rule mentions whitespace except the quoted text.
  `keyword` is `try (string' word <* notFollowedBy wordChar)`: case-insensitive, and `contain` is not
  `contains`. `try` matters: megaparsec's `<|>` only tries the second alternative if the first
  consumed no input, and a keyword that matched half a word has consumed some. `<?> "label"` replaces a
  pile of "expected 'c', 'a', ..." with "expected a condition".
- **Errors at the right place.** `failAt offset message = parseError (FancyError offset (Set.singleton
  (ErrorFail message)))` reports a custom problem at an earlier offset: the *start* of the amount, not
  the character after its third decimal. `problemFrom` turns the bundle into `RuleProblem {line, column,
  message}` with `reachOffset` (megaparsec computes the source position for an offset).
- **Semantic checks live in the parser** where they need no database: a third decimal, an account with no
  known type (`accountTypeFromName`, moved to the pure `AccountType` module so this module can use it),
  a split into a non-expense account, a friend named twice (`firstRepeat`, over `(offset, name)` pairs so
  the error lands on the second mention). Whether a friend *exists* needs the database; `Rules.checkRule`
  asks, and uses `problemAt` to find the name in the source and report line and column.
- **Exact amounts.** `amountParser` reads digits (with commas) and at most two decimals into an `Integer`
  of cents, rejects anything over $10^13, and builds `Cents`. There is no `Double` anywhere.
- **Renderer and the round-trip property.** `renderRule` writes the canonical form; the hedgehog property
  `parseRule (renderRule r) === Right r` runs over generated rules including quotes, backslashes and
  non-ASCII in the text. Writing the generator exposed the normalization rule: description text is kept
  upper-case with single spaces (`normalizeDescription`), so the generator normalizes too.

**Q: Why a parser combinator library rather than a regex or splitting on spaces?**
A: The grammar has quoted text with escapes, comparison operators, and a comma-separated list, and the
requirement is good errors, not just success. A combinator parser *is* the grammar (the code reads like it),
composes (`many (keyword "and" *> condition)`), and gets error recovery and positions for free. Splitting
on spaces would mis-handle `"TIM HORTONS"` and could never say "column 15".

**Q: What does `try` do, and why is it needed here?**
A: In megaparsec an alternative that fails *after consuming input* fails the whole choice, to give precise
errors and avoid exponential backtracking. `try p` pretends `p` consumed nothing if it fails. `keyword`
needs it because `string' "contains"` can match `contain` and then fail on the missing `s`: without `try`
the next alternative (`starts with`) would never be tried.

### `Reckon.Rules.Eval`: evaluation is a few lines

`holds :: Candidate -> Condition -> Bool` is one `case`. `Candidate` is what a rule can see (description,
amount, kind of account); the planner builds one from an `EvidenceRow`. Keeping evaluation separate from the
language means a new condition is a constructor, a parser case, a renderer case, and an evaluator case, and
the compiler's incomplete-pattern warning (an error under `-Werror`) finds any one you forgot.

### `Reckon.Posting.Classify`: `Rule`, `Outcome`, and a rule that can't apply

`Classify.Rule` is the *resolved* rule: `label`, `conditions`, and an `Outcome` (`ToAccount account` or
`SplitWith account friends`), with account ids from the database. The planner's rule step is
`mapMaybe (applyRule row) rules`, taking the first success. `applyRule` is in the `Maybe` monad:

```haskell
SplitWith account friends -> do
  friendAccounts <- Map.fromList . zip friendList <$> traverse (`Map.lookup` receivableOf) friendList
  split <- either (const Nothing) Just (equalSplit row.amount friendList)
  ...
```

`traverse` over a list in `Maybe` is "all of them found, or `Nothing`"; `either (const Nothing) Just`
turns a `SplitError` into "this rule doesn't apply". So a split of money coming in, an unknown friend, or a
share under a cent passes the rule over, and the next rule (or the guess) gets its turn. A property test
checks the parts of any split add up to the payment, and it found the under-a-cent case.

### `Reckon.Rules`: storage as text

The table holds `rule_text` and a priority, and nothing else: `loadRules` parses each stored text again and
looks up its accounts (`Map.fromListWith` over lower-cased names, since older accounts may not be lower
case). `addRule` = `checkRule` + `renderRule` + insert, and the `UNIQUE (rule_text)` constraint catches the
same rule written differently. The first test run caught a rule that differed only in the case of its
quoted text being saved twice, which is why the parser normalizes description text.

### `Reckon.Rules.History`: previewing and applying to the past

- `loadHistory` is one SQL statement: every imported row with `LEFT JOIN LATERAL` for its entry in effect
  and a `json_agg` subquery for the accounts that entry balances against (decoded with aeson, as in `Views`).
  `PostedAs` is `NotPosted | PostedTo account | PostedOtherwise` (a split, or through the clearing account).
- `previewRule :: Rule -> [HistoryRow] -> [PreviewRow]` is **pure**, so it is tested with plain lists. The
  `effectOn` function is one `case` over (action, how the row is posted) and its first line decides that a
  split of money in can't be carried out.
- `applyRule` moves the `WouldMoveFrom` rows through `recategorizeRow` / `splitRow`, collecting a refusal as
  a message instead of stopping.

**Q: Why not apply a new rule to history automatically?**
A: Because a rule is written to be right for the future, and applying it to the past rewrites hundreds
of entries. They're reversible (reversals dated like the originals), but a wrong rule would still churn
the ledger. So it's two steps: preview (read-only, live as you type), then an explicit apply.

**Q: How do you know applying a rule doesn't change any balance?**
A: It reuses `repostRow`, which reverses the old entry *dated like the original*. The test reads the bank
account's balance on every day of the month before and after and compares them, and a mutation check
(applying to rows the preview didn't list) fails the tests.

### The Rules page (frontend)

`RulesPage` keeps the text in `useState`, debounces it (`useDebounced`, 300 ms) and sends the settled text
to `/api/rules/check` with `useQuery`; `placeholderData: keepPreviousData` keeps the last answer on screen
instead of flashing. While the text differs from the settled text the answer is described as stale and Save
is off, so nothing can be saved on the strength of an answer about older text. A problem is shown as
`Line 1, column 15: ...` with the offending line and a caret (`pointAt`, a pure tested function).

---

## Scheduled jobs and reminders (Phase 7)

Design: D070-D073. Things the ledger can notice for itself, run on a schedule, with the results kept and
dismissible.

### `Reckon.Checks`: a check is a function

```haskell
runChecks :: Snapshot -> [Reminder]
```

All pure. `Snapshot` is a plain record of facts (today, each account's first transaction and statement
dates, open screenshot rows, due dates), so every check is tested with literals and `Day`s, no database and
no clock. The only calendar arithmetic is in `nextDueDate`, using `Data.Time.Calendar`
(`gregorianMonthLength`, `fromGregorian`); a month too short for the day clamps with `min`, and a property
test checks the result is never in the past, never more than 31 days ahead, and always on the right day.

- `missingStatementMonths` builds the infinite list `iterate nextMonth firstMonth` and cuts it with
  `takeWhile isDue`, which is safe because months are in order: the first month that hasn't ended ends the
  list. (Laziness doing what a `while` loop would.)
- `planReminders reported open` is the heart: `Map.notMember` / `Map.lookup` over `(kind, subject)` keys
  yields three lists (open, refresh, resolve). Two properties pin it down: when stored equals reported there
  is nothing to do, and every reminder is accounted for exactly once.

**Q: Why return reminders from a pure function and reconcile them with the database separately?**
A: Because "what is true today" and "what is stored" are different questions. Keeping the first pure makes
every rule testable in microseconds and by property; the second is a small, mechanical diff
(`planReminders`, also pure) applied by a thin DB function. The database only ever sees the three lists.

### `Reckon.Jobs`: a queue is a table and one query

`claimJob` is the whole trick:

```sql
UPDATE jobs SET status = 'running', locked_at = ?, attempts = attempts + 1
WHERE id = (SELECT id FROM jobs WHERE status = 'queued' AND run_at <= ?
            ORDER BY run_at, id LIMIT 1 FOR UPDATE SKIP LOCKED)
RETURNING id, kind, attempts
```

`FOR UPDATE` locks the row it picks, and `SKIP LOCKED` makes a second worker pass over a locked row instead
of waiting, so claiming is both exclusive and non-blocking. It's one statement, so there is no
read-then-write race. The Haskell around it is small functions in `SqlPersistT`: `ensureRecurring`
(`INSERT ... ON CONFLICT DO NOTHING` against the partial unique index), `completeJob`, `failJob` (a `case`
on `attempts < maxAttempts`), `requeueStuck`.

`runDueJobsWith handler pool now` runs each job in *separate* transactions: claim (commit, so the job reads as
`running` to everyone), run the handler inside `try`, then record the outcome. A handler that throws is
caught as a `SomeException` and becomes a `JobFailed`, so one bad job never stops the loop. The handler is a
parameter so a test can make one throw. `workerLoop` is `forever` over a `try`, with `threadDelay` between
passes, started with `forkIO` in `app/Main.hs`.

**Q: How do you test concurrency?**
A: One test gives two workers their own two-connection pool. The first claims inside a transaction it keeps
open (an `MVar` makes it wait), so its row lock is held; the second runs on another thread and must answer
"nothing to do" within five seconds. If the claim waited for the lock, the answer would never arrive and the
test fails. A mutation check (deleting `SKIP LOCKED`) confirms it does. Running the second worker on its own
thread matters: the first version blocked the test thread and hung instead of failing.

**Q: Why a database queue and not cron?**
A: A queue in the database is visible (a table you can read), testable (move the clock), recoverable (a
crashed worker's job comes back), and needs nothing installed. Cron is outside the application, so none of
those hold.

**Q: What stops the recurring job piling up?**
A: A partial unique index, `ON jobs (kind) WHERE status IN ('queued','running')`. Whatever the Haskell does,
the database refuses a second pending job. That's the repo's rule: integrity lives in the database, and a
raw-SQL test proves it.

### `Reckon.Reminders` and the clock

`loadSnapshot` runs three `rawSql` queries (accounts with `min(transaction_date)` and a `json_agg` of
statement dates; open screenshot rows with the day they were read; due dates through persistent). `checkNow`
loads the snapshot, runs the checks, loads the open reminders, calls `planReminders`, and applies the plan
with `insert` / `update`. Time never comes from `getCurrentTime` inside these: it is an argument, and the
server's handlers get it from `AppEnv.currentTime` (D072), which is how a test that lives in the year 3000
checks "which months have ended".

### The Reminders panel (frontend)

`RemindersPanel` (on the Review page) reads `GET /api/reminders` and shows each open reminder with a kind
label (`kindLabel`, an exhaustive `switch` with `satisfies never` over the generated `ReminderKindTag`), a
Dismiss button, "Check now", and a `<details>` for due dates with an add form that validates the day and
warning window before sending. Every action goes through `useAction`, which refetches everything.

---

## The HTTP API and the screens (Phase 6)

Phase 6 turns every CLI command into an endpoint and adds the pages. The design is in
D061–D065; this is the code.

### `Reckon.Api` and `Reckon.Server`: one route per CLI command

`Routes` (a `NamedRoutes` record) gained a field per endpoint, e.g.

```haskell
settleRow :: mode :- "rows" :> Capture "id" Int64 :> "settle" :> ReqBody '[JSON] SettleRequest :> Post '[JSON] ActionResult
```

so the path, the captured id, the body type and the answer type are one declaration, and a handler
with the wrong type is a compile error. Handlers are thin: parse (`parseDay`, `decodeFile`,
`bankAccountByLast4`), call the library function the CLI also calls, and turn the result into an
`ActionResult` with `resultFrom` (first line is the headline, the rest are details).

`refuse :: ServerError -> Text -> AppM a` is the one way to stop a request: it throws a Servant
`ServerError` whose body is an `ApiProblem` as JSON. Status codes say whose fault it was (400
malformed, 404 not found, 422 the ledger refused, 502 the model, 503 not configured).

**Q: Why return `{message, details}` for every action instead of a typed result per action?**
A: The CLI already had well-tested sentences for every outcome ("Posted 9 rows: 2 transfer legs..."),
and the UI's job is to show them. A typed result per action would mean the frontend re-deriving
those sentences, in a second language, and the two drifting. The wording lives once, in
`Reckon.Messages`, used by both.

### `Reckon.Messages`: refusals in words

One function per error type (`describePostingError`, `describeSplitRowError`, ...) that turns a
Haskell sum type into the sentence both the CLI and the API show. Pure and tiny. Pulling these out
of `cli/Main.hs` is what let the server reuse them.

### `Reckon.Views`: reads for the screens

Read-only functions in `SqlPersistT`, each answering one screen's question in the API's own types
(`AccountSummary`, `TransactionView`, `SpendingMonth`, `ReviewQueue`, ...).

- `accountSummaries` uses persistent for entities and `rawSql` for the two "how many rows are
  waiting" counts; the latest checkpoint is re-run through `reconcileAccount` so the explanation
  is always current, not a stored snapshot.
- `transactionsFor` is one SQL statement with `json_agg` collecting each entry's other lines
  into a JSON column, decoded with aeson. Parameters that may be absent are passed as
  `PersistNull` and tested in SQL (`?::date IS NULL OR ...`), so there is one query for every
  combination of filters and no string-built SQL.
- `reviewQueue` calls `Posting.reviewItems`, a **dry run** of posting: `postPendingRows` was split
  into `planCurrentRows` (decide) and the part that writes, and `reviewItems` runs only the first.
  The queue is therefore exactly what posting would leave behind, by construction, not a second
  copy of the rules.
- `wireCents :: Cents -> Int` is the one place the `Int64` ledger type narrows to the JSON number.
  JavaScript numbers are exact for integers up to 2^53 cents (about $90 trillion).

**Q: Why raw SQL for the transactions list?**
A: It needs a join across five tables, an aggregate per entry, and optional filters. In esqueleto
that is a page of type-level plumbing; here it is one readable statement. The rule in this repo is
that SQL reads are fine when they're parameterised and tested, and every write still goes
through the typed, constrained path.

### `Reckon.Security`: three small middlewares

`hostGuard :: [Text] -> Middleware` and `jsonOnlyWrites :: Middleware`. A WAI `Middleware` is
`Application -> Application`, and an `Application` is `Request -> (Response -> IO ResponseReceived)
-> IO ResponseReceived`, so a middleware that refuses just calls `respond` itself and never calls
the inner application. `hostAllowed` (pure, tested with a table of names) strips the port and
keeps the brackets of an IPv6 literal. The server's bind address is in `Config` (`host`, from
`RECKON_HOST`), and `app/Main.hs` applies it with `setHost`.

**Q: What is DNS rebinding and how does this stop it?**
A: A malicious page at `evil.example.com` can have its DNS answer change from the attacker's server
to `127.0.0.1` after the page loads. The browser then lets that page's scripts call
`http://evil.example.com:8080/api/...` as same-origin, which actually reaches your local API, so
no CORS rule applies. The request still says `Host: evil.example.com`, so the Host allowlist
refuses it. Binding to loopback alone doesn't help (the traffic *is* loopback), and CORS alone
doesn't help (the page is same-origin).

**Q: Why test the guard three ways?**
A: Each caught something the others couldn't. The in-process test found that a hand-built request
sets the `Host` header but not Warp's `requestHeaderHost` field, so the guard reads both. The
real-socket test (`testWithApplication`) proves the production path, where Warp fills the field in.
And a mutation check (turn the guard into `True`) showed the JSON-only middleware was untested
because Servant already refuses non-JSON bodies on routes that declare one, which is why it now
has a test on a bare `Application` with no body.

### `Reckon.App`: `screenshotReading`

`AppEnv` gained `screenshotReading :: ScreenshotReading`, a sum type decided once at startup:
`ReadingAvailable model extractor` when `ANTHROPIC_API_KEY` is set, else `ReadingUnavailable
reason`. Handlers pattern-match on it, so "no key" is a value, not a null checked in places. Tests
build an `AppEnv` with `ReadingAvailable` holding a scripted fake.

### `ApiSpec`: the whole loop over HTTP

`call env method path headers body` runs a request against `application env` with
`Network.Wai.Test` (no socket). The headline test imports a CSV, posts, reads the review queue,
settles three rows, records an opening balance and a statement, and asserts the account is
RECONCILED, all through JSON. It pins the scenario's `asOf` date to the end of its own unique
year, so it neither depends on today's date nor sees other tests' rows.

---

## The frontend (Phase 6)

| File | Role |
|---|---|
| `src/main.tsx` | Mounts React and provides the TanStack Query `QueryClient` (the cache for server data) |
| `src/App.tsx` | The shell: header, navigation, and a `switch` over the `Route` union to pick the page |
| `src/lib/route.ts`, `useHashRoute.ts` | A hash router in ~30 lines: `parseRoute`/`hrefFor` are pure and round-trip tested; the hook listens to `hashchange` |
| `src/lib/money.ts` | `formatCents` and `parseAmountToCents`: the only conversions between integer cents and text |
| `src/lib/useAction.ts` | `useMutation` plus "invalidate every query on success" |
| `src/lib/months.ts`, `bars.ts`, `plural.ts` | Small pure helpers (month names, UTC date arithmetic, a bar's width, "1 row / 2 rows") |
| `src/api/generated.ts` | **Generated** API types. Never edited by hand. |
| `src/api/client.ts` | One typed function per endpoint (`getJson`, `postJson`), `ApiError` that carries the server's `problem` text, and `toUploadedFile` (File → base64) |
| `src/pages/*Page.tsx` | One component per screen |
| `src/components/` | `Money`, `Notice` (shows a result or an error), `QueryState` (loading/error around a query), `BalanceForm`, `RowActions`, `LedgerAccountSelect`, `HealthBadge` |
| `src/testing.tsx` | `fakeBackend` and `renderWithQueries` for the component tests |

**Exhaustiveness.** `App`'s `Page` switch ends with `default: return route satisfies never`, and
`reasonLabel` does the same for the generated `ReviewReasonKind`. Add a page or a review reason
and the build fails until it is handled, including across the Haskell/TypeScript boundary.

**Money.** Amounts are integer cents from the API to the screen. `formatCents` splits a number
into dollars and cents with `%` and exact subtraction (no float division), and
`parseAmountToCents` is a regex (`^-?\d+(\.\d{1,2})?$`) so "1.234" is refused rather than rounded.
There is a test that formats and re-parses every amount from 0 to 20,000 cents.

**Server state.** Pages read with `useQuery` and never copy the result into component state.
Forms hold only what the person is typing. After any successful action `useAction` calls
`queryClient.invalidateQueries()`, so every page refetches; with six small pages that is simpler
than choosing which queries each action affects, and it can't leave one stale.

**Testing without a network.** `fakeBackend({'GET /api/accounts': [...]})` replaces `fetch`,
answers from a table, records every call, and throws on a request nobody expected. Tests assert
both on what the user sees and on the exact JSON a form sent (`balanceCents: 155243`, not
`1552.43`).

**Q: Why no router, state-management or UI library?**
A: Six pages and almost no client state. A hash router is 30 lines and a union type that the
compiler checks. TanStack Query is the state manager for server data; a form's own state is
`useState`. A component library would style forms and tables that are 90 lines of CSS here.
Fewer dependencies is also less to keep current, which matters for a project that should
still build in a year.

**Q: How do you stop a cross-site page from posting to your local API?**
A: See `Reckon.Security`. In short: writes must be `application/json`, which a cross-site form
can't send without a CORS preflight that is never answered; the Host header must be one of ours,
which stops DNS rebinding; and the server only listens on loopback.

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

Phase 3 adds:

| Spec | What it proves |
|---|---|
| `Posting.ClassifySpec` | Pure planner: rule priority, untracked-card payments (and a rule overriding the guess), uncategorized by sign, zero rows to review, transfer pairing within 5 days and not beyond, ambiguity goes to review, late re-pairing, cancelled e-Transfers. A **property** over random mixes of rows: each new row is posted or left for review exactly once, already-posted rows only come back as half of a pair, pairs are mutual, and clearing nets to zero. |
| `Reconcile.ExplainSpec` | Each `Finding` by example (reconciled, unposted rows close the gap, missing opening balance, duplicate, uncovered days, unexplained), and a **property** for `coverageGaps`. |
| `PostingSpec` | Against the database with `fixtures/rbc/february-two-accounts.csv`: every row lands on the right account; posting twice changes nothing; each account's balance equals its posted rows **on every date**; a guessed card payment is re-posted as a transfer when the Visa export arrives, without changing the balance on its date; the full reconciliation walkthrough (gap explained, rows settled with `post-row`, then reconciled); opening balance rules, including a card's; raw-SQL tests that evidence links and checkpoints can't be changed. And a **property** that imports random two-account exports and checks the reconciliation identity and that clearing nets to zero. |

**Mutation checks.** Removing the "mutual" condition from `pairUniquely`
fails 5 tests. Dating the re-post reversal a day late fails the late-pairing
test. Both were tried and reverted: the tests catch real mistakes.

Phase 4 adds:

| Spec | What it proves |
|---|---|
| `Posting.SplitSpec` | Pure: each `SplitError`, equal splits (including odd cents), and **properties**: any valid split's parts are positive and add up to the payment, friends who ask for more than was paid are always refused, `equalShares` adds up and differs by at most a cent. |
| `Posting.ClassifySpec` (extended) | Repayment suggestions: money in from a known person goes to review, every matching person is named, a rule overrides, money out and card credits are not suggestions. The main property now includes a person. |
| `SharingSpec` | Against the database with `fixtures/rbc/shared-dinner.csv`: a dinner split four ways leaves only my $30 as spending, each friend owing $30; repayments settle a receivable in full and in part; the bank balance still equals the posted rows on every date; exact-amount splits; an invalid split, unknown person or unknown account **changes nothing**; a transfer leg is refused; `recategorize`; people are unique by name and match text, and the database rejects bad rows when Haskell is bypassed. And a **property**: for random shares and a random remainder, the entry holds exactly the shares and my part, and they add up to what left the bank. |

Phase 5 adds:

| Spec | What it proves |
|---|---|
| `Screenshot.ExtractionSpec` | Dates (`Feb 14`, `Today`, 29 February, an explicit year, refusals), a **property** that `inferDate` is the latest matching date not after the screenshot, amounts as exact cents, and `parseExtraction` over the **fake recorded replies** in `fixtures/screenshots`: year inferred, signs from direction, partial rows dropped, uncertain rows kept, the whole reply rejected with every problem listed (including an account-number-shaped digit run), extra fields and non-JSON rejected. |
| `Screenshot.AlignSpec` | Joining by overlap, **identical rows kept**, ambiguity reported with the longest used, no overlap, wrong order, and a **property**: any scroll over distinct rows joins back exactly with no warnings. The two fake screenshots join into 8 rows with both coffees. |
| `Screenshot.MatchSpec` | Each rule of D057 by example (same amount, dates, a shared word, ambiguity, identical rows as a group, a pending hold posting for less), and **properties**: matches are one to one; `descriptionsAgree` is symmetric. |
| `Screenshot.ScoreSpec` | The evaluation scorer: perfect, missed, invented, misread description, misread amount. |
| `AnthropicSpec` | The request body (JSON-Schema format, base64 image, none of the parameters newer models reject), the response reader (thinking blocks, refusal, truncation), the redacted key, media type by magic bytes, and the real HTTP code against an **in-process stub server**: headers, retry on 429, no retry on 400, an unreachable host, and that the key never appears in an error. |
| `ScreenshotSpec` | Against the database with a **scripted fake extractor**: a two-screenshot scroll posts 7 provisional entries and holds the uncertain row; the same images or rows aren't read twice; the bank's CSV then confirms all eight and the ledger equals the CSV's on every date; the CSV-first order posts nothing for screenshots; a pending hold is replaced by its posted version and a released one is reversed; an unusable reply, an API error, a non-image and an unknown account store nothing and don't call the model; the reconciliation report names provisional rows as the gap; raw SQL: rows and uploads can't be changed and a contradictory resolution is refused. |

**Mutation checks.** Four bugs were planted and each was caught by a different test: confirming
without reversing the provisional entry, posting the uncertain rows, never checking the CSV for
rows it already has, and choosing the shortest overlap. All reverted.

`ScenarioSupport` holds the helpers `PostingSpec` and `SharingSpec` share
(`Scenario`, `importCsv`, `postedRows`, `entryLinesForRow`, ...).

Tests never delete anything (the journal forbids it). Each test makes its
own accounts with a unique suffix, and `make test` recreates the test
database on each run (DECISIONS D026).

Posting looks at **every** unposted row in the database, so `PostingSpec`
goes further (D047): each test is a `Scenario` with its own account
numbers, **its own year** (3000 + n, so no two tests' rows fall inside a
pairing window), and its own tag in descriptions (so its rules only match
its own rows). `forScenario` rewrites the fixture's text to match.

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
| **Evidence** | An imported bank row. Posting turns it into a journal entry and records the link in `journal_entry_evidence`. |
| **Counter account** | The other side of a posted row's entry: a category, `asset:clearing`, `liability:untracked-cards`, etc. |
| **Clearing account** | `asset:clearing`: where money sits between leaving one of my accounts and arriving in another (or between a payment and its cancellation). Zero once both sides have landed. |
| **Posted / unposted** | A row is posted when it has an evidence link to an entry that hasn't been reversed. |
| **Checkpoint** | A statement's closing balance for an account on a date. Reconciliation compares the ledger to it. |
| **Opening balance** | The account's balance before its first imported transaction, entered from a statement, posted against `equity:opening-balance`. |
| **Natural balance** | A balance with the sign a person expects: money in chequing, money owed on a card. The ledger stores raw debits (+) and credits (−). |
| **Reconciliation identity** | Ledger balance = opening balance + posted rows, for every account and date. |
| **Receivable** | `receivable:<name>`: an asset account holding what a friend owes me. Their share of a split debits it; their repayment credits it. |
| **Split** | One bank row shared between me and friends: one entry whose far side has a line per participant. |
| **Repost** | Replace a row's entry: reverse the old one (dated like the original) and post a new one. Never an edit. |
| **Tuple section** | `(name,)` is shorthand for a function that pairs `name` with its argument. |
| **Pattern guard** | A guard that also binds: `| Just x <- lookup key table = ...`. |
| **Provisional entry** | A journal entry posted from a screenshot row. It shows in the ledger until a bank row confirms it, when it is reversed (dated like the original). |
| **Open / resolved** | A screenshot row is open until it has a `provisional_resolutions` row: confirmed by a CSV, already in a CSV, superseded by a later screenshot, or released. |
| **Extractor** | A function from an image to the model's reply text: the seam that lets every test run without the real API. |
| **Overlap** | The rows shared by the bottom of one screenshot and the top of the next. |
| **ExceptT** | A monad transformer that adds early exit with an error (`throwError`) to another monad. `importScreenshots` stops at the first failure. |
| **Applicative style** | `Record <$> action1 <*> action2`: run several actions and combine their results into one value. |
