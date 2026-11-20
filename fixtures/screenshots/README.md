# Fake screenshot extractions

Hand-written stand-ins for what the model returns when asked to read a
screenshot of the bank app (`Reckon.Screenshot.Extraction`). Tests replay
them through a fake extractor, so **nothing here comes from a real
screenshot and no test calls the real API.**

| File | What it shows |
|---|---|
| `scroll-1.json` | The top of a scroll, taken on 2026-02-20: a pending $100 gas hold, a payroll deposit with a running balance, **two identical $4.50 coffees**, a grocery row, and a **partial** row cut off at the bottom (dropped). |
| `scroll-2.json` | The next screenshot of the same scroll. It starts with the second coffee and the grocery row (the overlap with `scroll-1`), then three new rows, one of them marked **uncertain**. Joining the two must keep both coffees. |
| `hold-pending.json` | Taken 2026-03-01: a **pending** $100.00 gas-station hold and a posted grocery row. |
| `hold-posted.json` | Taken 2026-03-05: the same hold now **posted** for $43.20, and the same grocery row. |
| `bad-rows.json` | Every kind of unusable row: an unreadable date, unknown direction, a minus sign on a credit, a zero amount, a long digit run that looks like an account number (in a description and in the account label), an unreadable amount, an empty description. The whole response must be rejected, listing each. |
| `extra-field.json` | A well-formed response with a field the schema doesn't allow. Rejected. |
