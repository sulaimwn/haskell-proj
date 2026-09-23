-- migrate:up

-- The ledger core: accounts, journal entries, and their lines.
--
-- Integrity rules enforced here, by the database itself (so they hold even
-- if the Haskell layer is bypassed):
--   1. Every journal entry has at least two lines and its lines sum to zero.
--   2. The journal is append-only: no UPDATE, DELETE or TRUNCATE.
--   3. Lines can only be added in the same transaction that created their
--      entry, so a committed entry can never gain lines later.
--   4. A reversal exactly cancels the entry it reverses, account by account,
--      and an entry can be reversed at most once.
--
-- Sign convention: debits are positive, credits are negative.

CREATE TABLE ledger_accounts (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- e.g. "asset:rbc-chequing", "expense:food", "receivable:alex"
  name TEXT NOT NULL UNIQUE CHECK (name ~ '^[a-z]+(:[a-z0-9-]+)+$'),
  account_type TEXT NOT NULL
    CHECK (account_type IN ('asset', 'liability', 'income', 'expense', 'equity')),
  -- Single-currency for now (DECISIONS D023). Relaxing this needs a
  -- per-currency balance rule first.
  currency TEXT NOT NULL DEFAULT 'CAD' CHECK (currency = 'CAD'),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE journal_entries (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  occurred_on DATE NOT NULL,
  description TEXT NOT NULL CHECK (description <> ''),
  -- UNIQUE: an entry can be reversed at most once.
  reverses_entry_id BIGINT UNIQUE REFERENCES journal_entries (id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- The transaction that created this entry. Rule 3 compares against it.
  created_in_transaction BIGINT NOT NULL DEFAULT txid_current(),
  CHECK (reverses_entry_id IS NULL OR reverses_entry_id <> id)
);

CREATE TABLE journal_lines (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entry_id BIGINT NOT NULL REFERENCES journal_entries (id),
  ledger_account_id BIGINT NOT NULL REFERENCES ledger_accounts (id),
  -- Debit positive, credit negative. A zero line carries no information.
  amount_cents BIGINT NOT NULL CHECK (amount_cents <> 0)
);

CREATE INDEX journal_lines_entry_id_idx ON journal_lines (entry_id);
CREATE INDEX journal_lines_ledger_account_id_idx ON journal_lines (ledger_account_id);
CREATE INDEX journal_entries_occurred_on_idx ON journal_entries (occurred_on);

-- Rules 1 and 4, for one entry. Called from deferred triggers, i.e. at
-- COMMIT, once the entry and all its lines have been inserted.
CREATE FUNCTION check_journal_entry(target_entry_id BIGINT) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  line_count INTEGER;
  line_total NUMERIC;
  reversed_entry_id BIGINT;
  uncancelled_accounts INTEGER;
BEGIN
  SELECT count(*), coalesce(sum(amount_cents), 0)
    INTO line_count, line_total
    FROM journal_lines
    WHERE entry_id = target_entry_id;

  IF line_count < 2 THEN
    RAISE EXCEPTION 'journal entry % has % line(s); an entry needs at least 2',
      target_entry_id, line_count
      USING ERRCODE = 'check_violation';
  END IF;

  IF line_total <> 0 THEN
    RAISE EXCEPTION 'journal entry % is unbalanced: its lines sum to % cents',
      target_entry_id, line_total
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT reverses_entry_id INTO reversed_entry_id
    FROM journal_entries
    WHERE id = target_entry_id;

  IF reversed_entry_id IS NOT NULL THEN
    -- Together, the entry and its reversal must net to zero in every account.
    SELECT count(*) INTO uncancelled_accounts
      FROM (
        SELECT ledger_account_id
          FROM journal_lines
          WHERE entry_id IN (target_entry_id, reversed_entry_id)
          GROUP BY ledger_account_id
          HAVING sum(amount_cents) <> 0
      ) AS accounts_left_over;

    IF uncancelled_accounts > 0 THEN
      RAISE EXCEPTION 'journal entry % does not exactly reverse entry %',
        target_entry_id, reversed_entry_id
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
END;
$$;

CREATE FUNCTION check_journal_entry_after_entry_insert() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM check_journal_entry(NEW.id);
  RETURN NULL;
END;
$$;

CREATE FUNCTION check_journal_entry_after_line_insert() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM check_journal_entry(NEW.entry_id);
  RETURN NULL;
END;
$$;

-- DEFERRABLE INITIALLY DEFERRED: run at COMMIT, not after each INSERT,
-- because an entry is necessarily unbalanced while its lines are still
-- being inserted. The entry-level trigger catches an entry with no lines.
CREATE CONSTRAINT TRIGGER journal_entry_is_balanced
  AFTER INSERT ON journal_entries
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION check_journal_entry_after_entry_insert();

CREATE CONSTRAINT TRIGGER journal_line_entry_is_balanced
  AFTER INSERT ON journal_lines
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION check_journal_entry_after_line_insert();

-- Rule 3.
CREATE FUNCTION reject_lines_for_committed_entries() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM journal_entries
      WHERE id = NEW.entry_id
        AND created_in_transaction = txid_current()
  ) THEN
    RAISE EXCEPTION 'cannot add lines to journal entry %: it was created in an earlier transaction',
      NEW.entry_id
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER journal_lines_only_with_their_entry
  BEFORE INSERT ON journal_lines
  FOR EACH ROW EXECUTE FUNCTION reject_lines_for_committed_entries();

-- Rule 2.
CREATE FUNCTION reject_journal_modification() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% is append-only: % is not allowed. Post a reversing entry instead.',
    TG_TABLE_NAME, TG_OP
    USING ERRCODE = 'integrity_constraint_violation';
END;
$$;

CREATE TRIGGER journal_entries_are_append_only
  BEFORE UPDATE OR DELETE ON journal_entries
  FOR EACH ROW EXECUTE FUNCTION reject_journal_modification();

CREATE TRIGGER journal_entries_cannot_be_truncated
  BEFORE TRUNCATE ON journal_entries
  FOR EACH STATEMENT EXECUTE FUNCTION reject_journal_modification();

CREATE TRIGGER journal_lines_are_append_only
  BEFORE UPDATE OR DELETE ON journal_lines
  FOR EACH ROW EXECUTE FUNCTION reject_journal_modification();

CREATE TRIGGER journal_lines_cannot_be_truncated
  BEFORE TRUNCATE ON journal_lines
  FOR EACH STATEMENT EXECUTE FUNCTION reject_journal_modification();

-- migrate:down

DROP TABLE journal_lines;
DROP TABLE journal_entries;
DROP TABLE ledger_accounts;
DROP FUNCTION reject_journal_modification();
DROP FUNCTION reject_lines_for_committed_entries();
DROP FUNCTION check_journal_entry_after_line_insert();
DROP FUNCTION check_journal_entry_after_entry_insert();
DROP FUNCTION check_journal_entry(BIGINT);
