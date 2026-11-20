-- migrate:up

-- Phase 5: transactions read from screenshots of the bank app by Claude.
-- They are evidence of lower quality than a CSV export, so they live in
-- their own tables, are posted as provisional entries, and are resolved
-- when a CSV (or a later screenshot) supersedes them. Everything here is
-- append-only.

-- One row per screenshot file. The hash stops the same image being read
-- twice. extraction_json is the model's reply, stored only after it passed
-- validation (which refuses anything that looks like an account number).
CREATE TABLE screenshot_uploads (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  file_sha256 TEXT NOT NULL UNIQUE CHECK (file_sha256 ~ '^[0-9a-f]{64}$'),
  file_name TEXT NOT NULL,
  bank_account_id BIGINT NOT NULL REFERENCES bank_accounts (id),
  -- The day the screenshot was taken: "Today", "Yesterday" and year-less
  -- dates are read against it.
  taken_on DATE NOT NULL,
  model_id TEXT NOT NULL CHECK (model_id <> ''),
  account_label TEXT NOT NULL,
  extraction_json TEXT NOT NULL,
  partial_rows_dropped INTEGER NOT NULL CHECK (partial_rows_dropped >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER screenshot_uploads_are_append_only
  BEFORE UPDATE OR DELETE ON screenshot_uploads
  FOR EACH ROW EXECUTE FUNCTION reject_evidence_modification();

-- A transaction read from a screenshot, after joining overlapping
-- screenshots. Same identity scheme as raw_bank_rows: (account, date,
-- fingerprint, occurrence). The fingerprint includes whether the row was
-- pending, so a hold and its later posted version are different rows.
CREATE TABLE screenshot_rows (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  upload_id BIGINT NOT NULL REFERENCES screenshot_uploads (id),
  bank_account_id BIGINT NOT NULL REFERENCES bank_accounts (id),
  transaction_date DATE NOT NULL,
  description TEXT NOT NULL CHECK (description <> ''),
  -- Negative is money out, as in raw_bank_rows.
  amount_cents BIGINT NOT NULL CHECK (amount_cents <> 0),
  running_balance_cents BIGINT,
  is_pending BOOLEAN NOT NULL,
  -- The model said it wasn't sure. Kept, never posted.
  uncertain BOOLEAN NOT NULL,
  fingerprint TEXT NOT NULL,
  occurrence INTEGER NOT NULL CHECK (occurrence >= 1),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (bank_account_id, transaction_date, fingerprint, occurrence)
);

CREATE INDEX screenshot_rows_upload_id_idx ON screenshot_rows (upload_id);

CREATE TRIGGER screenshot_rows_are_append_only
  BEFORE UPDATE OR DELETE ON screenshot_rows
  FOR EACH ROW EXECUTE FUNCTION reject_evidence_modification();

-- Which provisional entry was posted from which screenshot row.
CREATE TABLE screenshot_entry_evidence (
  entry_id BIGINT NOT NULL REFERENCES journal_entries (id),
  screenshot_row_id BIGINT NOT NULL REFERENCES screenshot_rows (id),
  PRIMARY KEY (entry_id, screenshot_row_id)
);

CREATE INDEX screenshot_entry_evidence_screenshot_row_id_idx ON screenshot_entry_evidence (screenshot_row_id);

CREATE TRIGGER screenshot_entry_evidence_is_append_only
  BEFORE UPDATE OR DELETE ON screenshot_entry_evidence
  FOR EACH ROW EXECUTE FUNCTION reject_journal_modification();

-- How a screenshot row stopped being provisional. A screenshot row with no
-- resolution (and a provisional entry in effect) is "open".
--   confirmed_by_csv         a CSV row for the same transaction arrived; the
--                            provisional entry was reversed
--   already_in_csv           the CSV row was already there when the
--                            screenshot was read, so no entry was posted
--   superseded_by_screenshot a later screenshot shows it posted (a pending
--                            hold became a real transaction); reversed
--   released                 the owner said it never posted; reversed
CREATE TABLE provisional_resolutions (
  screenshot_row_id BIGINT PRIMARY KEY REFERENCES screenshot_rows (id),
  kind TEXT NOT NULL
    CHECK (kind IN ('confirmed_by_csv', 'already_in_csv', 'superseded_by_screenshot', 'released')),
  raw_bank_row_id BIGINT UNIQUE REFERENCES raw_bank_rows (id),
  superseded_by_screenshot_row_id BIGINT UNIQUE REFERENCES screenshot_rows (id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (
    (kind IN ('confirmed_by_csv', 'already_in_csv')
      AND raw_bank_row_id IS NOT NULL AND superseded_by_screenshot_row_id IS NULL)
    OR (kind = 'superseded_by_screenshot'
      AND superseded_by_screenshot_row_id IS NOT NULL AND raw_bank_row_id IS NULL)
    OR (kind = 'released'
      AND raw_bank_row_id IS NULL AND superseded_by_screenshot_row_id IS NULL)
  )
);

CREATE TRIGGER provisional_resolutions_are_append_only
  BEFORE UPDATE OR DELETE ON provisional_resolutions
  FOR EACH ROW EXECUTE FUNCTION reject_evidence_modification();

-- migrate:down

DROP TABLE provisional_resolutions;
DROP TABLE screenshot_entry_evidence;
DROP TABLE screenshot_rows;
DROP TABLE screenshot_uploads;
