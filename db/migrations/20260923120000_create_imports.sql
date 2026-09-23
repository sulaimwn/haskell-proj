-- migrate:up

-- Imported evidence: what the bank says happened, before it becomes journal
-- entries (Phase 3).
--
-- Deduplication (DECISIONS D029): bank CSVs have no transaction IDs, so a
-- row is identified by (account, date, fingerprint, occurrence), where the
-- fingerprint is the normalized description + cheque number + amount, and
-- the occurrence numbers identical rows within a day (coffee #1, coffee #2).
-- Importing an overlapping export only adds occurrences not already stored.

-- A real account at a bank. Only the last 4 digits of the account number are
-- ever stored (docs/PRIVACY.md).
CREATE TABLE bank_accounts (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  institution TEXT NOT NULL CHECK (institution IN ('rbc')),
  account_kind TEXT NOT NULL CHECK (account_kind IN ('chequing', 'savings', 'credit_card')),
  last4 TEXT NOT NULL CHECK (last4 ~ '^[0-9]{4}$'),
  nickname TEXT NOT NULL CHECK (nickname <> ''),
  -- The ledger account that mirrors this bank account (e.g. asset:rbc-chequing-1234).
  ledger_account_id BIGINT NOT NULL UNIQUE REFERENCES ledger_accounts (id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (institution, account_kind, last4)
);

-- One imported file. The SHA-256 of its bytes makes re-importing the exact
-- same file a no-op.
CREATE TABLE import_batches (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source TEXT NOT NULL CHECK (source IN ('csv', 'screenshot')),
  file_sha256 TEXT NOT NULL UNIQUE CHECK (file_sha256 ~ '^[0-9a-f]{64}$'),
  file_name TEXT NOT NULL,
  imported_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Which accounts and dates a batch covered. One RBC export can contain
-- several accounts. The first and last dates matter because an export's edge
-- days may be incomplete (an export taken mid-day).
CREATE TABLE import_batch_coverage (
  batch_id BIGINT NOT NULL REFERENCES import_batches (id),
  bank_account_id BIGINT NOT NULL REFERENCES bank_accounts (id),
  first_date DATE NOT NULL,
  last_date DATE NOT NULL,
  rows_in_file INTEGER NOT NULL CHECK (rows_in_file > 0),
  rows_added INTEGER NOT NULL CHECK (rows_added >= 0),
  PRIMARY KEY (batch_id, bank_account_id),
  CHECK (first_date <= last_date)
);

CREATE TABLE raw_bank_rows (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  bank_account_id BIGINT NOT NULL REFERENCES bank_accounts (id),
  -- The batch that first contained this row. Later overlapping batches
  -- that contain it again add nothing.
  first_seen_batch_id BIGINT NOT NULL REFERENCES import_batches (id),
  transaction_date DATE NOT NULL,
  -- As exported, before normalization.
  description_1 TEXT NOT NULL,
  description_2 TEXT NOT NULL,
  cheque_number TEXT NOT NULL,
  amount_cents BIGINT NOT NULL,
  fingerprint TEXT NOT NULL,
  occurrence INTEGER NOT NULL CHECK (occurrence >= 1),
  -- The dedupe key. The database refuses a second copy of the same
  -- transaction, even if the import logic has a bug.
  UNIQUE (bank_account_id, transaction_date, fingerprint, occurrence)
);

CREATE INDEX raw_bank_rows_first_seen_batch_id_idx ON raw_bank_rows (first_seen_batch_id);

-- Things an import couldn't decide on its own. Resolving them is Phase 6's
-- review queue. Resolutions will live in their own table, like
-- everything else here, since these rows are never modified.
CREATE TABLE import_review_items (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  batch_id BIGINT NOT NULL REFERENCES import_batches (id),
  bank_account_id BIGINT NOT NULL REFERENCES bank_accounts (id),
  transaction_date DATE NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('missing_from_newer_export', 'possible_duplicate')),
  -- The stored row the item is about.
  raw_bank_row_id BIGINT NOT NULL REFERENCES raw_bank_rows (id),
  -- For possible_duplicate: the newly added row that may be the same transaction.
  related_raw_bank_row_id BIGINT REFERENCES raw_bank_rows (id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK ((kind = 'possible_duplicate') = (related_raw_bank_row_id IS NOT NULL))
);

-- Evidence is immutable, like the journal: what the bank said doesn't change.
CREATE FUNCTION reject_evidence_modification() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% is append-only: % is not allowed. Imported evidence is never changed.',
    TG_TABLE_NAME, TG_OP
    USING ERRCODE = 'integrity_constraint_violation';
END;
$$;

CREATE TRIGGER raw_bank_rows_are_append_only
  BEFORE UPDATE OR DELETE ON raw_bank_rows
  FOR EACH ROW EXECUTE FUNCTION reject_evidence_modification();

CREATE TRIGGER raw_bank_rows_cannot_be_truncated
  BEFORE TRUNCATE ON raw_bank_rows
  FOR EACH STATEMENT EXECUTE FUNCTION reject_evidence_modification();

CREATE TRIGGER import_batches_are_append_only
  BEFORE UPDATE OR DELETE ON import_batches
  FOR EACH ROW EXECUTE FUNCTION reject_evidence_modification();

CREATE TRIGGER import_batch_coverage_is_append_only
  BEFORE UPDATE OR DELETE ON import_batch_coverage
  FOR EACH ROW EXECUTE FUNCTION reject_evidence_modification();

CREATE TRIGGER import_review_items_are_append_only
  BEFORE UPDATE OR DELETE ON import_review_items
  FOR EACH ROW EXECUTE FUNCTION reject_evidence_modification();

-- migrate:down

DROP TABLE import_review_items;
DROP TABLE raw_bank_rows;
DROP TABLE import_batch_coverage;
DROP TABLE import_batches;
DROP TABLE bank_accounts;
DROP FUNCTION reject_evidence_modification();
