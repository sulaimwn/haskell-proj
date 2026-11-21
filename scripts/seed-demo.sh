#!/usr/bin/env bash
# Fills the DEMO database with the fake dataset in fixtures/demo, using the
# same commands you would use on real data (import, post, rules, splits,
# statements, screenshots). Run by scripts/demo.sh; see fixtures/demo/README.md
# for what the dataset contains and where each hard case is.
#
# It refuses to run against any database but reckon_demo: the data is fake and
# must never land in a database that holds real data.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

RECKON_DEMO=1 load_env
case "$DATABASE_URL" in
  */reckon_demo\?*) ;;
  *) echo "error: refusing to seed anything but the reckon_demo database (DATABASE_URL=$DATABASE_URL)" >&2; exit 1 ;;
esac

(cd backend && cabal build -v0 exe:reckon-cli)
cli_binary="$(cd backend && cabal list-bin exe:reckon-cli)"
cli() { "$cli_binary" "$@"; }
sql() { docker compose exec -T db psql -U reckon -d reckon_demo -tAc "$1"; }

# The id of an imported row, by when it happened and a bit of its description.
row_id() { sql "SELECT id FROM raw_bank_rows WHERE transaction_date = '$1' AND description_1 || ' ' || description_2 ILIKE '%$2%' ORDER BY id LIMIT 1"; }

demo=fixtures/demo
chequing=2468
savings=3579
visa=1357

log "Importing bank exports (the second chequing export overlaps the first)"
cli import-rbc-csv "$demo/chequing-sep-oct.csv"
cli import-rbc-csv "$demo/chequing-oct-nov.csv"
cli import-rbc-csv "$demo/savings-sep-nov.csv"
cli import-rbc-csv "$demo/visa-sep-nov.csv"

log "Friends and rules"
cli add-person alex "ALEX EXAMPLE"
cli add-person sam "SAM EXAMPLE"
cli add-rule 'when description contains "PAYROLL" then categorize income:salary'
cli add-rule 'when description contains "LANDLORD" then categorize expense:rent'
cli add-rule 'when description contains "GROCERY" then categorize expense:groceries'
cli add-rule 'when description contains "HYDRO" then categorize expense:utilities'
cli add-rule 'when description contains "INTERNET" then categorize expense:internet'
cli add-rule 'when description contains "MOBILE" then categorize expense:phone'
cli add-rule 'when description contains "COFFEE" then categorize expense:coffee'
cli add-rule 'when description contains "GAS" then categorize expense:fuel'
cli add-rule 'when description contains "STREAMING" then categorize expense:subscriptions'
cli add-rule 'when description contains "BOOKSHOP" then categorize expense:books'
cli add-rule 'when description contains "SHOE STORE" then categorize expense:clothing'
cli add-rule 'when description contains "ELECTRONICS" then categorize expense:electronics'
cli add-rule 'when description contains "RESTAURANT" then categorize expense:restaurants'
# A big dinner is shared three ways; a small one is just mine. The first
# rule that matches wins, so the split rule goes first.
cli add-rule 'when description contains "QUIBBLE BISTRO" and amount <= -100.00 then split expense:food equally with alex, sam' 50
cli add-rule 'when description contains "QUIBBLE BISTRO" then categorize expense:restaurants' 60

log "Opening balances, then posting"
cli opening-balance "$chequing" 2026-08-31 2000.00
cli opening-balance "$savings" 2026-08-31 5000.00
cli opening-balance "$visa" 2026-08-31 350.00
cli post

log "Alex paid his share of the dinner; Sam's stays in the review queue as a possible repayment"
cli post-row "$(row_id 2026-10-14 'ALEX EXAMPLE')" receivable:alex

log "Statement balances, as printed on the statements (see fixtures/demo/README.md)"
cli checkpoint "$chequing" 2026-09-30 3247.74
cli checkpoint "$chequing" 2026-10-31 6456.06
cli checkpoint "$savings" 2026-09-30 5004.17
cli checkpoint "$savings" 2026-10-31 5308.55
cli checkpoint "$visa" 2026-09-30 121.48
cli checkpoint "$visa" 2026-10-31 7.22
# Mid-month: three transfer rows are still waiting for a decision, so these
# two don't reconcile yet, and the report says why.
cli checkpoint "$chequing" 2026-11-15 6577.97
cli checkpoint "$visa" 2026-11-15 20.30

log "Screenshots of the app, read by a local stand-in for the API (no key, no network)"
work="$(mktemp -d)"
stub_pid=""
cleanup() {
  if [[ -n "$stub_pid" ]]; then kill "$stub_pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
# Not real images: the stand-in ignores them. They only need a PNG header, and
# a different body each, so each counts as a different screenshot.
printf '\x89PNG\r\n\x1a\ndemo screenshot 1' >"$work/shot-1.png"
printf '\x89PNG\r\n\x1a\ndemo screenshot 2' >"$work/shot-2.png"
node scripts/stub-anthropic.mjs "$demo/screenshot-1.json" "$demo/screenshot-2.json" >"$work/stub.log" &
stub_pid=$!
for _ in $(seq 1 50); do grep -q '^PORT ' "$work/stub.log" 2>/dev/null && break; sleep 0.1; done
stub_port="$(sed -n 's/^PORT //p' "$work/stub.log")"
ANTHROPIC_API_KEY=sk-demo-stand-in ANTHROPIC_BASE_URL="http://127.0.0.1:$stub_port" \
  cli import-screenshots "$chequing" --taken 2026-11-20 "$work/shot-1.png" "$work/shot-2.png"

log "The bank's next export confirms the screenshot rows, and the hold that never posted is released"
cli import-rbc-csv "$demo/chequing-nov-16-19.csv"
cli post
cli release-provisional "$(sql "SELECT id FROM screenshot_rows WHERE description ILIKE 'PLINTH HOTEL%' ORDER BY id LIMIT 1")"

log "A due date, and the first run of the daily checks"
cli add-due-date "Visa payment" 28 7
cli run-checks

log "Checking the demo came out the way fixtures/demo/README.md says"
expect() {
  if [[ "$2" != "$3" ]]; then
    echo "demo check failed: $1: got '$2', wanted '$3'" >&2
    exit 1
  fi
}
resolutions() { sql "SELECT count(*) FROM provisional_resolutions WHERE kind = '$1'"; }
balance_of() { sql "SELECT coalesce(sum(l.amount_cents), 0) FROM journal_lines l JOIN ledger_accounts a ON a.id = l.ledger_account_id WHERE a.name = '$1'"; }
expect "screenshot rows confirmed by the bank's CSV (a tip, a lower hold, a grocery row)" "$(resolutions confirmed_by_csv)" 3
expect "screenshot rows that were already in a CSV" "$(resolutions already_in_csv)" 1
expect "holds released" "$(resolutions released)" 1
expect "screenshot rows still waiting for a CSV" "$(sql "SELECT count(*) FROM screenshot_rows s WHERE NOT EXISTS (SELECT 1 FROM provisional_resolutions p WHERE p.screenshot_row_id = s.id)")" 2
expect "imported rows left for a decision (three ambiguous transfers and Sam's repayment)" "$(sql "SELECT count(*) FROM raw_bank_rows r WHERE NOT EXISTS (SELECT 1 FROM journal_entry_evidence ev WHERE ev.raw_bank_row_id = r.id AND NOT EXISTS (SELECT 1 FROM journal_entries rev WHERE rev.reverses_entry_id = ev.entry_id))")" 4
expect "statements that reconcile to the cent" "$(cli reconcile | grep -c RECONCILED)" 5
expect "what Alex owes after his repayment (cents)" "$(balance_of receivable:alex)" 0
expect "what Sam owes (cents)" "$(balance_of receivable:sam)" 4000
expect "my share of the dinner (cents)" "$(balance_of expense:food)" 4000
expect "money through the clearing account (transfers and pairs net to zero, cents)" "$(balance_of asset:clearing)" 0

log "Demo data is ready."
