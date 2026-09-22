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
- [Tests](#tests)
- [Frontend](#frontend)
- [Glossary](#glossary)

---

## The shape of the backend

`backend/reckon.cabal` defines four **components** that share one library:

| Component | Directory | What it is |
|---|---|---|
| `library` | `src/` | All the real code. Everything below lives here. |
| `executable reckon-server` | `app/` | A few lines: load config, build the pool, start the HTTP server. |
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

From Phase 1, **hedgehog** property tests generate random sequences of ledger
operations and check that invariants hold for all of them.

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
