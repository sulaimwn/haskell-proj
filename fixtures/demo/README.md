# The demo dataset

**All of this is invented.** Names, merchants, amounts and account numbers are
made up, and nothing here came from a real bank or a real screenshot. It is
loaded by `make demo` (`scripts/demo.sh` → `scripts/seed-demo.sh`) into its own
database, `reckon_demo`, so your development database is never touched, and the
seed script refuses to run against any other database.

It is a three-month story (September to November 2026) for one person with a
chequing account (`…2468`), a savings account (`…3579`) and a Visa (`…1357`),
told with the same commands you would use on real data.

## The files

| File | What it is |
|---|---|
| `chequing-sep-oct.csv` | The first chequing export, Sep 1 to Oct 31, oldest first. |
| `chequing-oct-nov.csv` | The second export, **Oct 15 to Nov 15, newest first**, overlapping the first. Importing it adds only the new November rows. |
| `chequing-nov-16-19.csv` | The bank's next export, a few days later (Nov 16 to 19). |
| `savings-sep-nov.csv`, `visa-sep-nov.csv` | One export each, Sep 1 (or the first interest) to Nov 15. |
| `screenshot-1.json`, `screenshot-2.json` | What the model "read" from two overlapping screenshots of the app, taken Nov 20. Served by `scripts/stub-anthropic.mjs`, a local stand-in for the API: **no key, no network, no real screenshot.** |

## Where each hard case is

| Case | Where |
|---|---|
| **Two identical same-day coffees** | Sep 12 and Oct 10 (chequing), and again on Nov 20 in the screenshots. Both are kept, never collapsed. |
| **Overlapping imports** | `chequing-oct-nov.csv` repeats Oct 15 to 31. Importing it says "added" only for November. |
| **A transfer between your accounts** | The Visa payments on Sep 28 and Oct 28 (chequing → Visa) and the monthly transfer to savings. Each pairs with its other half through `asset:clearing`, so none of it counts as spending. |
| **A cancelled e-Transfer** | Oct 8 sent, Oct 9 cancelled (chequing). A pair, so it nets to zero. |
| **A refund** | The shoe store purchase on Oct 19 and its return on Oct 22 (Visa). |
| **A bill payment** | Hydro, internet and mobile: "Online Banking payment" rows, categorized by rules. |
| **A split dinner and repayments** | Oct 11, a $120 dinner. A split rule shares it three ways ($40 is mine, $40 each is what Alex and Sam owe). Alex's e-Transfer on Oct 14 is applied to his balance; **Sam's on Oct 15 is left in Review** as a possible repayment. |
| **A pending hold that posts for a different amount** | The restaurant on Nov 17: pending at $40.00 in the screenshot, posted at **$48.00** (a tip) in the bank's next export. The provisional entry is replaced. |
| **A gas-station hold that posts lower** | Nov 19: pending at $100.00, posted at **$43.20**. |
| **A hold that is released** | The hotel hold on Nov 15 ($75.00 pending) never posts. The seed releases it. |
| **Rows already in the CSV** | The payroll deposit in the screenshots is already in the second export, so nothing is posted twice. |
| **Overlapping screenshots** | `screenshot-1.json` ends with the Nov 18 grocery row that `screenshot-2.json` begins with. They are joined by that overlap. |
| **Ambiguous transfers** | Nov 3: chequing −$200, and two +$200 on the Visa (a payment on Nov 4, a return on Nov 5). Which goes with which is not clear, so all three wait in Review. |
| **Statements that reconcile, and one that doesn't, with a reason** | Sep 30 and Oct 31 for the savings account and the Visa reconcile to the cent. The chequing Oct 31 and the mid-month (Nov 15) statements show a gap, and the report names the rows that close it. |
| **Reminders** | A due date ("Visa payment", the 28th, 7 days ahead) shows on the Review page. |

## Not here: a USD purchase and refund

reckon is CAD-only (DECISIONS D023). A USD row is **rejected with a
line-numbered error**, not guessed at: see `fixtures/rbc/malformed.csv`. A real
foreign-currency design is a known gap (docs/STATUS.md).

## Statement balances

They were computed from the CSVs (opening balance plus the rows up to the date,
the card's as money owed), not from the ledger, so a reconciled statement is
evidence and not a tautology:

| Statement | Chequing | Savings | Visa (owed) |
|---|---|---|---|
| Opening, Aug 31 | 2,000.00 | 5,000.00 | 350.00 |
| Sep 30 | 3,247.74 | 5,004.17 | 121.48 |
| Oct 31 | 6,456.06 | 5,308.55 | 7.22 |
| Nov 15 | 6,577.97 | 5,610.75 | 20.30 |

## Why every merchant has its own made-up name

An earlier draft ended every merchant in "EXAMPLE". Matching a pending hold to
the bank's row accepts one word in common (D057), so a hold at "HOTEL EXAMPLE"
quietly matched an unrelated bill from "EXAMPLE INTERNET" on the strength of that
one word. Real merchants don't all share a word, so the fixture was unrealistic;
each now has its own invented name (and the friends keep the `EXAMPLE` surname,
since only pending rows are matched by words).
