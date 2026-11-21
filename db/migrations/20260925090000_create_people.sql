-- migrate:up

-- Phase 4: people I share expenses with. Each has a receivable account
-- (receivable:<name>) holding what they owe me, and a piece of text that
-- appears in their e-Transfers, so a repayment can be recognized.
-- This is configuration, not a financial record, so rows may be edited.
CREATE TABLE people (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- Lower-case, no spaces: it becomes part of the receivable account name.
  name TEXT NOT NULL CHECK (name ~ '^[a-z0-9][a-z0-9-]*$'),
  -- Matched against the upper-cased, whitespace-collapsed descriptions of
  -- incoming rows, like categorization_rules.description_contains.
  match_text TEXT NOT NULL
    CHECK (match_text <> '' AND match_text = upper(match_text)),
  ledger_account_id BIGINT NOT NULL REFERENCES ledger_accounts (id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (name),
  UNIQUE (match_text),
  UNIQUE (ledger_account_id)
);

-- migrate:down

DROP TABLE people;
