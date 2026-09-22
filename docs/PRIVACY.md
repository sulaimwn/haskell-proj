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
5. **Screenshots are sent to Anthropic's API** (from Phase 5). Crop out
   anything you don't want to send before uploading.

## How the rules are enforced

| Layer | What it catches |
|---|---|
| `.gitignore` | `/private/`, `.env`, `.env.*` (except `.env.example`) never show up as untracked files to add. |
| Pre-commit hook (`.githooks/pre-commit`) | Blocks a commit that stages anything under `private/`, any `.env` file, or any data-shaped file (`.csv`, `.ofx`, `.qfx`, `.pdf`, `.png`, `.jpg`, ...) outside the allowed folders (`fixtures/`, `docs/images/`, `frontend/public/`, `frontend/src/assets/`). `make dev` and `make hooks` install it. |
| CI (`privacy-guard` job) | The same check over every tracked file, so a commit made without the hook still fails CI. |
| Code (from Phase 2) | Parsers truncate account numbers to the last 4 digits at the boundary. Tests assert this. |

The hook runs **before** the commit, which matters: once something reaches a
public GitHub repo, you have to treat it as leaked even if you delete it
later. CI only catches it after the push.

## If real data gets committed anyway

1. Don't push. If it's only local: `git reset --soft HEAD~1`, unstage the
   file, move it into `/private`, and commit again.
2. If it was pushed: treat it as leaked. Rewrite history to remove it (e.g.
   `git filter-repo`), force-push, and ask GitHub support to purge cached
   views. If a key leaked, revoke it in the Anthropic console immediately.
