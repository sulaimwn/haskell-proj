-- migrate:up

-- Phase 3: turning imported evidence into journal entries, and proving the
-- ledger matches bank statements.

-- Which bank row an entry was posted from. Every entry posted from evidence
-- has exactly one row here (DECISIONS D039), and a row is posted at most
-- once unless its entry was later reversed (checked by Reckon.Posting).
CREATE TABLE journal_entry_evidence (
  entry_id BIGINT NOT NULL REFERENCES journal_entries (id),
  raw_bank_row_id BIGINT NOT NULL REFERENCES raw_bank_rows (id),
  PRIMARY KEY (entry_id, raw_bank_row_id)
);

CREATE INDEX journal_entry_evidence_raw_bank_row_id_idx ON journal_entry_evidence (raw_bank_row_id);

CREATE TRIGGER journal_entry_evidence_is_append_only
  BEFORE UPDATE OR DELETE ON journal_entry_evidence
  FOR EACH ROW EXECUTE FUNCTION reject_journal_modification();

-- "Description contains X → ledger account". A deliberately small rule
-- format. Phase 7 replaces it with a rule language. Rules are
-- configuration, not financial records, so they may be edited.
CREATE TABLE categorization_rules (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- Matched against the upper-cased, whitespace-collapsed descriptions.
  description_contains TEXT NOT NULL
    CHECK (description_contains <> '' AND description_contains = upper(description_contains)),
  ledger_account_id BIGINT NOT NULL REFERENCES ledger_accounts (id),
  -- Lower runs first; ties go to the older rule.
  priority INTEGER NOT NULL DEFAULT 100,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (description_contains)
);

-- The balance printed on a bank statement, as the bank shows it: money in
-- a chequing account, or the amount owed on a credit card.
CREATE TABLE statement_checkpoints (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  bank_account_id BIGINT NOT NULL REFERENCES bank_accounts (id),
  as_of_date DATE NOT NULL,
  statement_balance_cents BIGINT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (bank_account_id, as_of_date)
);

CREATE TRIGGER statement_checkpoints_are_append_only
  BEFORE UPDATE OR DELETE ON statement_checkpoints
  FOR EACH ROW EXECUTE FUNCTION reject_evidence_modification();

-- The journal entry that records a bank account's balance before its first
-- imported transaction. Changing it means reversing that entry and
-- recording a new one; the current one is the entry that isn't reversed.
CREATE TABLE opening_balances (
  entry_id BIGINT PRIMARY KEY REFERENCES journal_entries (id),
  bank_account_id BIGINT NOT NULL REFERENCES bank_accounts (id),
  as_of_date DATE NOT NULL
);

CREATE INDEX opening_balances_bank_account_id_idx ON opening_balances (bank_account_id);

CREATE TRIGGER opening_balances_are_append_only
  BEFORE UPDATE OR DELETE ON opening_balances
  FOR EACH ROW EXECUTE FUNCTION reject_journal_modification();

-- migrate:down

DROP TABLE opening_balances;
DROP TABLE statement_checkpoints;
DROP TABLE categorization_rules;
DROP TABLE journal_entry_evidence;
