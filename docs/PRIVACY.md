# Privacy

reckon processes real banking data. The repository may be public. These rules
are non-negotiable.

## The rules

1. **Real data lives in `/private` and nowhere else in the repo.** Bank CSVs,
   screenshots, statements, and eval labels all go under `/private`, which is
   gitignored.
2. **`/fixtures` holds only fake data.** Invented merchants, invented amounts,
   and account numbers that are obviously fake (e.g. `00000-1234567`).
3. **Never store a full account number.** Parsers keep the last 4 digits and
   drop the rest before anything is written to the database.
4. **Secrets live in `.env`** (gitignored). The Anthropic API key is read by
   the backend only. It is never sent to the frontend or logged.
5. **Friends' names are personal data too.** The `people` table (names and
   the text their e-Transfers contain) lives only in your local database.
   Fixtures use obviously fake names (ALEX EXAMPLE).
6. **Screenshots are sent to Anthropic's API** by `import-screenshots` and
   `eval-screenshots`, using your own key, from the backend only. Crop out
   anything you don't want sent before reading them. Keep screenshots, and the
   hand-written labels for the evaluation, in `private/` (e.g. `private/screenshots`,
   `private/eval`): the commit guard blocks images anywhere else.
7. **The API is reachable only from your own browser (Phase 6).** It has no login, so
   `reckon-server` binds `127.0.0.1`, refuses requests addressed to any other host name
   (DNS rebinding), and refuses writes that aren't JSON (cross-site forms). Don't widen
   `RECKON_HOST` or `RECKON_ALLOWED_HOSTS`; a login must come first (D061).
8. **Only what the model read is kept, not the image.** The database stores the
   image's SHA-256, its file name, and the model's *validated* reply. The model
   is told never to return an account number, and the reply is rejected if any
   description or the account label contains nine or more digits in a row.

## How the rules are enforced

| Layer | What it catches |
|---|---|
| `.gitignore` | `/private/`, `.env`, `.env.*` (except `.env.example`) never show up as untracked files to add. |
| Pre-commit hook (`.githooks/pre-commit`) | Blocks a commit that stages anything under `private/`, any `.env` file, or any data-shaped file (`.csv`, `.ofx`, `.qfx`, `.pdf`, `.png`, `.jpg`, ...) outside the allowed folders (`fixtures/`, `docs/images/`, `frontend/public/`, `frontend/src/assets/`). `make dev` and `make hooks` install it. |
| CI (`privacy-guard` job) | The same check over every tracked file, so a commit made without the hook still fails CI. |
| Code | The RBC parser keeps only the last 4 digits (`Last4` can't hold more), `bank_accounts.last4` has a 4-digit CHECK, and a test scans every stored column after an import to prove the full number appears nowhere. |
| Code (Phase 5) | `ApiKey` has a hand-written `Show` that prints `<redacted>`; the request header is marked redacted; errors are built from the API's response, never from the request; a test asserts the key appears in no error or `show` output. Tests never call the real API: they use scripted fakes, hand-written fixtures (`fixtures/screenshots`, no real screenshot), and an in-process stub server. `parseExtraction` rejects a reply with an account-number-shaped digit run before anything is stored. |
| Network (Phase 6) | `Reckon.Config` defaults `RECKON_HOST` to `127.0.0.1`; `hostGuard` answers 403 to any `Host` not in `RECKON_ALLOWED_HOSTS`; `jsonOnlyWrites` answers 415 to a write that isn't JSON. Tested in-process, over a real socket, and by mutation (the guards disabled make tests fail). Uploaded CSVs and screenshots travel from the browser to the local server only; the server forwards screenshots (not CSVs) to Anthropic. Request logging is Apache-style (method, path, status) and never includes bodies (D066). |
| Workflow | `make import` warns if the file isn't under `private/`. `make post`, `make reconcile`, `owed`, `spending` and `checkpoint` print real descriptions, names and amounts to your terminal: when asking for help, share the kind of problem (e.g. "3 rows left for review, ambiguous transfer") or the parser's line-numbered errors, not the output itself. |

The hook runs **before** the commit, which matters: once something reaches a
public GitHub repo, you have to treat it as leaked even if you delete it
later. CI only catches it after the push.

## If real data gets committed anyway

1. Don't push. If it's only local: `git reset --soft HEAD~1`, unstage the
   file, move it into `/private`, and commit again.
2. If it was pushed: treat it as leaked. Rewrite history to remove it (e.g.
   `git filter-repo`), force-push, and ask GitHub support to purge cached
   views. If a key leaked, revoke it in the Anthropic console immediately.
