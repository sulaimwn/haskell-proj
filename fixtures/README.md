# Fixtures

**Fake data only.** Everything in this folder is invented and safe to publish.
Real exports and screenshots go in `/private` (gitignored). See
[docs/PRIVACY.md](../docs/PRIVACY.md).

Fixtures are added as their phases need them:

| Phase | Fixtures |
|---|---|
| 2 | `rbc/`: RBC-format CSV exports covering overlapping ranges, same-day duplicates, a partial last day, a renamed row, a vanished row, and a malformed file (see `rbc/README.md`) |
| 5 | Recorded (fake) Claude extraction responses, including malformed JSON, partial rows, and overlapping screenshots |
| 8 | The full demo dataset used by the seed script |
