# Fake RBC CSV exports

All data here is invented. The account number `00000-0001234` is fake, and
tests replace it with a unique one per test.

| File | What it exercises |
|---|---|
| `january.csv` | Jan 2–31. Two identical $4.50 coffees on Jan 20; a quoted description containing a comma; an e-Transfer and a bill payment; **Jan 31 is partial** (one coffee, as if exported mid-day). |
| `mid-january-to-mid-february.csv` | Jan 15–Feb 13, **newest first**, overlapping `january.csv`. Jan 20 has the same two coffees (nothing added); Jan 31 now has two coffees (one added); the Jan 22 grocery row was **renamed** (`#12` → `#0012`, flagged as a possible duplicate); the Jan 25 bookshop row is **missing** (flagged); three February rows are new. |
| `malformed.csv` | One valid row and four broken ones (impossible date, bad amount, USD-only, unknown account type). The whole file must be rejected with line numbers. |

Expected results are asserted in `backend/test/Reckon/ImportSpec.hs`.
