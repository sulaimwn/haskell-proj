\restrict dbmate

-- Dumped from database version 17.11 (Debian 17.11-1.pgdg13+2)
-- Dumped by pg_dump version 18.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: check_journal_entry(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_journal_entry(target_entry_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: check_journal_entry_after_entry_insert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_journal_entry_after_entry_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM check_journal_entry(NEW.id);
  RETURN NULL;
END;
$$;


--
-- Name: check_journal_entry_after_line_insert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_journal_entry_after_line_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM check_journal_entry(NEW.entry_id);
  RETURN NULL;
END;
$$;


--
-- Name: reject_evidence_modification(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reject_evidence_modification() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION '% is append-only: % is not allowed. Imported evidence is never changed.',
    TG_TABLE_NAME, TG_OP
    USING ERRCODE = 'integrity_constraint_violation';
END;
$$;


--
-- Name: reject_journal_modification(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reject_journal_modification() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION '% is append-only: % is not allowed. Post a reversing entry instead.',
    TG_TABLE_NAME, TG_OP
    USING ERRCODE = 'integrity_constraint_violation';
END;
$$;


--
-- Name: reject_lines_for_committed_entries(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reject_lines_for_committed_entries() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: bank_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bank_accounts (
    id bigint NOT NULL,
    institution text NOT NULL,
    account_kind text NOT NULL,
    last4 text NOT NULL,
    nickname text NOT NULL,
    ledger_account_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT bank_accounts_account_kind_check CHECK ((account_kind = ANY (ARRAY['chequing'::text, 'savings'::text, 'credit_card'::text]))),
    CONSTRAINT bank_accounts_institution_check CHECK ((institution = 'rbc'::text)),
    CONSTRAINT bank_accounts_last4_check CHECK ((last4 ~ '^[0-9]{4}$'::text)),
    CONSTRAINT bank_accounts_nickname_check CHECK ((nickname <> ''::text))
);


--
-- Name: bank_accounts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.bank_accounts ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.bank_accounts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: due_dates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.due_dates (
    id bigint NOT NULL,
    label text NOT NULL,
    day_of_month integer NOT NULL,
    warn_days integer DEFAULT 5 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT due_dates_day_of_month_check CHECK (((day_of_month >= 1) AND (day_of_month <= 31))),
    CONSTRAINT due_dates_label_check CHECK ((btrim(label) <> ''::text)),
    CONSTRAINT due_dates_warn_days_check CHECK (((warn_days >= 0) AND (warn_days <= 28)))
);


--
-- Name: due_dates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.due_dates ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.due_dates_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: import_batch_coverage; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.import_batch_coverage (
    batch_id bigint NOT NULL,
    bank_account_id bigint NOT NULL,
    first_date date NOT NULL,
    last_date date NOT NULL,
    rows_in_file integer NOT NULL,
    rows_added integer NOT NULL,
    CONSTRAINT import_batch_coverage_check CHECK ((first_date <= last_date)),
    CONSTRAINT import_batch_coverage_rows_added_check CHECK ((rows_added >= 0)),
    CONSTRAINT import_batch_coverage_rows_in_file_check CHECK ((rows_in_file > 0))
);


--
-- Name: import_batches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.import_batches (
    id bigint NOT NULL,
    source text NOT NULL,
    file_sha256 text NOT NULL,
    file_name text NOT NULL,
    imported_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT import_batches_file_sha256_check CHECK ((file_sha256 ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT import_batches_source_check CHECK ((source = ANY (ARRAY['csv'::text, 'screenshot'::text])))
);


--
-- Name: import_batches_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.import_batches ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.import_batches_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: import_review_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.import_review_items (
    id bigint NOT NULL,
    batch_id bigint NOT NULL,
    bank_account_id bigint NOT NULL,
    transaction_date date NOT NULL,
    kind text NOT NULL,
    raw_bank_row_id bigint NOT NULL,
    related_raw_bank_row_id bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT import_review_items_check CHECK (((kind = 'possible_duplicate'::text) = (related_raw_bank_row_id IS NOT NULL))),
    CONSTRAINT import_review_items_kind_check CHECK ((kind = ANY (ARRAY['missing_from_newer_export'::text, 'possible_duplicate'::text])))
);


--
-- Name: import_review_items_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.import_review_items ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.import_review_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.jobs (
    id bigint NOT NULL,
    kind text NOT NULL,
    run_at timestamp with time zone NOT NULL,
    status text NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    locked_at timestamp with time zone,
    finished_at timestamp with time zone,
    last_error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT jobs_attempts_check CHECK ((attempts >= 0)),
    CONSTRAINT jobs_check CHECK (((status = 'running'::text) = (locked_at IS NOT NULL))),
    CONSTRAINT jobs_kind_check CHECK ((kind = 'run_checks'::text)),
    CONSTRAINT jobs_status_check CHECK ((status = ANY (ARRAY['queued'::text, 'running'::text, 'succeeded'::text, 'failed'::text])))
);


--
-- Name: jobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.jobs ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.jobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: journal_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.journal_entries (
    id bigint NOT NULL,
    occurred_on date NOT NULL,
    description text NOT NULL,
    reverses_entry_id bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_in_transaction bigint DEFAULT txid_current() NOT NULL,
    CONSTRAINT journal_entries_check CHECK (((reverses_entry_id IS NULL) OR (reverses_entry_id <> id))),
    CONSTRAINT journal_entries_description_check CHECK ((description <> ''::text))
);


--
-- Name: journal_entries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.journal_entries ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.journal_entries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: journal_entry_evidence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.journal_entry_evidence (
    entry_id bigint NOT NULL,
    raw_bank_row_id bigint NOT NULL
);


--
-- Name: journal_lines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.journal_lines (
    id bigint NOT NULL,
    entry_id bigint NOT NULL,
    ledger_account_id bigint NOT NULL,
    amount_cents bigint NOT NULL,
    CONSTRAINT journal_lines_amount_cents_check CHECK ((amount_cents <> 0))
);


--
-- Name: journal_lines_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.journal_lines ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.journal_lines_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: ledger_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ledger_accounts (
    id bigint NOT NULL,
    name text NOT NULL,
    account_type text NOT NULL,
    currency text DEFAULT 'CAD'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ledger_accounts_account_type_check CHECK ((account_type = ANY (ARRAY['asset'::text, 'liability'::text, 'income'::text, 'expense'::text, 'equity'::text]))),
    CONSTRAINT ledger_accounts_currency_check CHECK ((currency = 'CAD'::text)),
    CONSTRAINT ledger_accounts_name_check CHECK ((name ~ '^[a-z]+(:[a-z0-9-]+)+$'::text))
);


--
-- Name: ledger_accounts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.ledger_accounts ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.ledger_accounts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: opening_balances; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.opening_balances (
    entry_id bigint NOT NULL,
    bank_account_id bigint NOT NULL,
    as_of_date date NOT NULL
);


--
-- Name: people; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.people (
    id bigint NOT NULL,
    name text NOT NULL,
    match_text text NOT NULL,
    ledger_account_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT people_match_text_check CHECK (((match_text <> ''::text) AND (match_text = upper(match_text)))),
    CONSTRAINT people_name_check CHECK ((name ~ '^[a-z0-9][a-z0-9-]*$'::text))
);


--
-- Name: people_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.people ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.people_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: posting_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.posting_rules (
    id bigint NOT NULL,
    rule_text text NOT NULL,
    priority integer DEFAULT 100 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT posting_rules_rule_text_check CHECK ((btrim(rule_text) <> ''::text))
);


--
-- Name: posting_rules_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.posting_rules ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.posting_rules_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: provisional_resolutions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.provisional_resolutions (
    screenshot_row_id bigint NOT NULL,
    kind text NOT NULL,
    raw_bank_row_id bigint,
    superseded_by_screenshot_row_id bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT provisional_resolutions_check CHECK ((((kind = ANY (ARRAY['confirmed_by_csv'::text, 'already_in_csv'::text])) AND (raw_bank_row_id IS NOT NULL) AND (superseded_by_screenshot_row_id IS NULL)) OR ((kind = 'superseded_by_screenshot'::text) AND (superseded_by_screenshot_row_id IS NOT NULL) AND (raw_bank_row_id IS NULL)) OR ((kind = 'released'::text) AND (raw_bank_row_id IS NULL) AND (superseded_by_screenshot_row_id IS NULL)))),
    CONSTRAINT provisional_resolutions_kind_check CHECK ((kind = ANY (ARRAY['confirmed_by_csv'::text, 'already_in_csv'::text, 'superseded_by_screenshot'::text, 'released'::text])))
);


--
-- Name: raw_bank_rows; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.raw_bank_rows (
    id bigint NOT NULL,
    bank_account_id bigint NOT NULL,
    first_seen_batch_id bigint NOT NULL,
    transaction_date date NOT NULL,
    description_1 text NOT NULL,
    description_2 text NOT NULL,
    cheque_number text NOT NULL,
    amount_cents bigint NOT NULL,
    fingerprint text NOT NULL,
    occurrence integer NOT NULL,
    CONSTRAINT raw_bank_rows_occurrence_check CHECK ((occurrence >= 1))
);


--
-- Name: raw_bank_rows_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.raw_bank_rows ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.raw_bank_rows_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: reminders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reminders (
    id bigint NOT NULL,
    kind text NOT NULL,
    subject text NOT NULL,
    message text NOT NULL,
    detected_at timestamp with time zone NOT NULL,
    resolved_at timestamp with time zone,
    dismissed_at timestamp with time zone,
    CONSTRAINT reminders_kind_check CHECK ((kind = ANY (ARRAY['statement_missing'::text, 'provisional_stale'::text, 'due_soon'::text]))),
    CONSTRAINT reminders_message_check CHECK ((message <> ''::text)),
    CONSTRAINT reminders_subject_check CHECK ((subject <> ''::text))
);


--
-- Name: reminders_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.reminders ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.reminders_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: screenshot_entry_evidence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.screenshot_entry_evidence (
    entry_id bigint NOT NULL,
    screenshot_row_id bigint NOT NULL
);


--
-- Name: screenshot_rows; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.screenshot_rows (
    id bigint NOT NULL,
    upload_id bigint NOT NULL,
    bank_account_id bigint NOT NULL,
    transaction_date date NOT NULL,
    description text NOT NULL,
    amount_cents bigint NOT NULL,
    running_balance_cents bigint,
    is_pending boolean NOT NULL,
    uncertain boolean NOT NULL,
    fingerprint text NOT NULL,
    occurrence integer NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT screenshot_rows_amount_cents_check CHECK ((amount_cents <> 0)),
    CONSTRAINT screenshot_rows_description_check CHECK ((description <> ''::text)),
    CONSTRAINT screenshot_rows_occurrence_check CHECK ((occurrence >= 1))
);


--
-- Name: screenshot_rows_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.screenshot_rows ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.screenshot_rows_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: screenshot_uploads; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.screenshot_uploads (
    id bigint NOT NULL,
    file_sha256 text NOT NULL,
    file_name text NOT NULL,
    bank_account_id bigint NOT NULL,
    taken_on date NOT NULL,
    model_id text NOT NULL,
    account_label text NOT NULL,
    extraction_json text NOT NULL,
    partial_rows_dropped integer NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT screenshot_uploads_file_sha256_check CHECK ((file_sha256 ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT screenshot_uploads_model_id_check CHECK ((model_id <> ''::text)),
    CONSTRAINT screenshot_uploads_partial_rows_dropped_check CHECK ((partial_rows_dropped >= 0))
);


--
-- Name: screenshot_uploads_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.screenshot_uploads ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.screenshot_uploads_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: statement_checkpoints; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.statement_checkpoints (
    id bigint NOT NULL,
    bank_account_id bigint NOT NULL,
    as_of_date date NOT NULL,
    statement_balance_cents bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: statement_checkpoints_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.statement_checkpoints ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.statement_checkpoints_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: bank_accounts bank_accounts_institution_account_kind_last4_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bank_accounts
    ADD CONSTRAINT bank_accounts_institution_account_kind_last4_key UNIQUE (institution, account_kind, last4);


--
-- Name: bank_accounts bank_accounts_ledger_account_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bank_accounts
    ADD CONSTRAINT bank_accounts_ledger_account_id_key UNIQUE (ledger_account_id);


--
-- Name: bank_accounts bank_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bank_accounts
    ADD CONSTRAINT bank_accounts_pkey PRIMARY KEY (id);


--
-- Name: due_dates due_dates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.due_dates
    ADD CONSTRAINT due_dates_pkey PRIMARY KEY (id);


--
-- Name: import_batch_coverage import_batch_coverage_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_batch_coverage
    ADD CONSTRAINT import_batch_coverage_pkey PRIMARY KEY (batch_id, bank_account_id);


--
-- Name: import_batches import_batches_file_sha256_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_batches
    ADD CONSTRAINT import_batches_file_sha256_key UNIQUE (file_sha256);


--
-- Name: import_batches import_batches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_batches
    ADD CONSTRAINT import_batches_pkey PRIMARY KEY (id);


--
-- Name: import_review_items import_review_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_review_items
    ADD CONSTRAINT import_review_items_pkey PRIMARY KEY (id);


--
-- Name: jobs jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_pkey PRIMARY KEY (id);


--
-- Name: journal_entries journal_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entries
    ADD CONSTRAINT journal_entries_pkey PRIMARY KEY (id);


--
-- Name: journal_entries journal_entries_reverses_entry_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entries
    ADD CONSTRAINT journal_entries_reverses_entry_id_key UNIQUE (reverses_entry_id);


--
-- Name: journal_entry_evidence journal_entry_evidence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entry_evidence
    ADD CONSTRAINT journal_entry_evidence_pkey PRIMARY KEY (entry_id, raw_bank_row_id);


--
-- Name: journal_lines journal_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_lines
    ADD CONSTRAINT journal_lines_pkey PRIMARY KEY (id);


--
-- Name: ledger_accounts ledger_accounts_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_accounts
    ADD CONSTRAINT ledger_accounts_name_key UNIQUE (name);


--
-- Name: ledger_accounts ledger_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_accounts
    ADD CONSTRAINT ledger_accounts_pkey PRIMARY KEY (id);


--
-- Name: opening_balances opening_balances_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_balances
    ADD CONSTRAINT opening_balances_pkey PRIMARY KEY (entry_id);


--
-- Name: people people_ledger_account_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.people
    ADD CONSTRAINT people_ledger_account_id_key UNIQUE (ledger_account_id);


--
-- Name: people people_match_text_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.people
    ADD CONSTRAINT people_match_text_key UNIQUE (match_text);


--
-- Name: people people_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.people
    ADD CONSTRAINT people_name_key UNIQUE (name);


--
-- Name: people people_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.people
    ADD CONSTRAINT people_pkey PRIMARY KEY (id);


--
-- Name: posting_rules posting_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.posting_rules
    ADD CONSTRAINT posting_rules_pkey PRIMARY KEY (id);


--
-- Name: posting_rules posting_rules_rule_text_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.posting_rules
    ADD CONSTRAINT posting_rules_rule_text_key UNIQUE (rule_text);


--
-- Name: provisional_resolutions provisional_resolutions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provisional_resolutions
    ADD CONSTRAINT provisional_resolutions_pkey PRIMARY KEY (screenshot_row_id);


--
-- Name: provisional_resolutions provisional_resolutions_raw_bank_row_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provisional_resolutions
    ADD CONSTRAINT provisional_resolutions_raw_bank_row_id_key UNIQUE (raw_bank_row_id);


--
-- Name: provisional_resolutions provisional_resolutions_superseded_by_screenshot_row_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provisional_resolutions
    ADD CONSTRAINT provisional_resolutions_superseded_by_screenshot_row_id_key UNIQUE (superseded_by_screenshot_row_id);


--
-- Name: raw_bank_rows raw_bank_rows_bank_account_id_transaction_date_fingerprint__key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.raw_bank_rows
    ADD CONSTRAINT raw_bank_rows_bank_account_id_transaction_date_fingerprint__key UNIQUE (bank_account_id, transaction_date, fingerprint, occurrence);


--
-- Name: raw_bank_rows raw_bank_rows_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.raw_bank_rows
    ADD CONSTRAINT raw_bank_rows_pkey PRIMARY KEY (id);


--
-- Name: reminders reminders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reminders
    ADD CONSTRAINT reminders_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: screenshot_entry_evidence screenshot_entry_evidence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screenshot_entry_evidence
    ADD CONSTRAINT screenshot_entry_evidence_pkey PRIMARY KEY (entry_id, screenshot_row_id);


--
-- Name: screenshot_rows screenshot_rows_bank_account_id_transaction_date_fingerprin_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screenshot_rows
    ADD CONSTRAINT screenshot_rows_bank_account_id_transaction_date_fingerprin_key UNIQUE (bank_account_id, transaction_date, fingerprint, occurrence);


--
-- Name: screenshot_rows screenshot_rows_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screenshot_rows
    ADD CONSTRAINT screenshot_rows_pkey PRIMARY KEY (id);


--
-- Name: screenshot_uploads screenshot_uploads_file_sha256_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screenshot_uploads
    ADD CONSTRAINT screenshot_uploads_file_sha256_key UNIQUE (file_sha256);


--
-- Name: screenshot_uploads screenshot_uploads_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screenshot_uploads
    ADD CONSTRAINT screenshot_uploads_pkey PRIMARY KEY (id);


--
-- Name: statement_checkpoints statement_checkpoints_bank_account_id_as_of_date_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.statement_checkpoints
    ADD CONSTRAINT statement_checkpoints_bank_account_id_as_of_date_key UNIQUE (bank_account_id, as_of_date);


--
-- Name: statement_checkpoints statement_checkpoints_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.statement_checkpoints
    ADD CONSTRAINT statement_checkpoints_pkey PRIMARY KEY (id);


--
-- Name: jobs_due_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX jobs_due_idx ON public.jobs USING btree (run_at) WHERE (status = 'queued'::text);


--
-- Name: jobs_one_pending_per_kind; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX jobs_one_pending_per_kind ON public.jobs USING btree (kind) WHERE (status = ANY (ARRAY['queued'::text, 'running'::text]));


--
-- Name: journal_entries_occurred_on_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX journal_entries_occurred_on_idx ON public.journal_entries USING btree (occurred_on);


--
-- Name: journal_entry_evidence_raw_bank_row_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX journal_entry_evidence_raw_bank_row_id_idx ON public.journal_entry_evidence USING btree (raw_bank_row_id);


--
-- Name: journal_lines_entry_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX journal_lines_entry_id_idx ON public.journal_lines USING btree (entry_id);


--
-- Name: journal_lines_ledger_account_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX journal_lines_ledger_account_id_idx ON public.journal_lines USING btree (ledger_account_id);


--
-- Name: opening_balances_bank_account_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX opening_balances_bank_account_id_idx ON public.opening_balances USING btree (bank_account_id);


--
-- Name: raw_bank_rows_first_seen_batch_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX raw_bank_rows_first_seen_batch_id_idx ON public.raw_bank_rows USING btree (first_seen_batch_id);


--
-- Name: reminders_one_open_per_subject; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX reminders_one_open_per_subject ON public.reminders USING btree (kind, subject) WHERE (resolved_at IS NULL);


--
-- Name: screenshot_entry_evidence_screenshot_row_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX screenshot_entry_evidence_screenshot_row_id_idx ON public.screenshot_entry_evidence USING btree (screenshot_row_id);


--
-- Name: screenshot_rows_upload_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX screenshot_rows_upload_id_idx ON public.screenshot_rows USING btree (upload_id);


--
-- Name: import_batch_coverage import_batch_coverage_is_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER import_batch_coverage_is_append_only BEFORE DELETE OR UPDATE ON public.import_batch_coverage FOR EACH ROW EXECUTE FUNCTION public.reject_evidence_modification();


--
-- Name: import_batches import_batches_are_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER import_batches_are_append_only BEFORE DELETE OR UPDATE ON public.import_batches FOR EACH ROW EXECUTE FUNCTION public.reject_evidence_modification();


--
-- Name: import_review_items import_review_items_are_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER import_review_items_are_append_only BEFORE DELETE OR UPDATE ON public.import_review_items FOR EACH ROW EXECUTE FUNCTION public.reject_evidence_modification();


--
-- Name: journal_entries journal_entries_are_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER journal_entries_are_append_only BEFORE DELETE OR UPDATE ON public.journal_entries FOR EACH ROW EXECUTE FUNCTION public.reject_journal_modification();


--
-- Name: journal_entries journal_entries_cannot_be_truncated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER journal_entries_cannot_be_truncated BEFORE TRUNCATE ON public.journal_entries FOR EACH STATEMENT EXECUTE FUNCTION public.reject_journal_modification();


--
-- Name: journal_entry_evidence journal_entry_evidence_is_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER journal_entry_evidence_is_append_only BEFORE DELETE OR UPDATE ON public.journal_entry_evidence FOR EACH ROW EXECUTE FUNCTION public.reject_journal_modification();


--
-- Name: journal_entries journal_entry_is_balanced; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER journal_entry_is_balanced AFTER INSERT ON public.journal_entries DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.check_journal_entry_after_entry_insert();


--
-- Name: journal_lines journal_line_entry_is_balanced; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER journal_line_entry_is_balanced AFTER INSERT ON public.journal_lines DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.check_journal_entry_after_line_insert();


--
-- Name: journal_lines journal_lines_are_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER journal_lines_are_append_only BEFORE DELETE OR UPDATE ON public.journal_lines FOR EACH ROW EXECUTE FUNCTION public.reject_journal_modification();


--
-- Name: journal_lines journal_lines_cannot_be_truncated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER journal_lines_cannot_be_truncated BEFORE TRUNCATE ON public.journal_lines FOR EACH STATEMENT EXECUTE FUNCTION public.reject_journal_modification();


--
-- Name: journal_lines journal_lines_only_with_their_entry; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER journal_lines_only_with_their_entry BEFORE INSERT ON public.journal_lines FOR EACH ROW EXECUTE FUNCTION public.reject_lines_for_committed_entries();


--
-- Name: opening_balances opening_balances_are_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER opening_balances_are_append_only BEFORE DELETE OR UPDATE ON public.opening_balances FOR EACH ROW EXECUTE FUNCTION public.reject_journal_modification();


--
-- Name: provisional_resolutions provisional_resolutions_are_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER provisional_resolutions_are_append_only BEFORE DELETE OR UPDATE ON public.provisional_resolutions FOR EACH ROW EXECUTE FUNCTION public.reject_evidence_modification();


--
-- Name: raw_bank_rows raw_bank_rows_are_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER raw_bank_rows_are_append_only BEFORE DELETE OR UPDATE ON public.raw_bank_rows FOR EACH ROW EXECUTE FUNCTION public.reject_evidence_modification();


--
-- Name: raw_bank_rows raw_bank_rows_cannot_be_truncated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER raw_bank_rows_cannot_be_truncated BEFORE TRUNCATE ON public.raw_bank_rows FOR EACH STATEMENT EXECUTE FUNCTION public.reject_evidence_modification();


--
-- Name: screenshot_entry_evidence screenshot_entry_evidence_is_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER screenshot_entry_evidence_is_append_only BEFORE DELETE OR UPDATE ON public.screenshot_entry_evidence FOR EACH ROW EXECUTE FUNCTION public.reject_journal_modification();


--
-- Name: screenshot_rows screenshot_rows_are_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER screenshot_rows_are_append_only BEFORE DELETE OR UPDATE ON public.screenshot_rows FOR EACH ROW EXECUTE FUNCTION public.reject_evidence_modification();


--
-- Name: screenshot_uploads screenshot_uploads_are_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER screenshot_uploads_are_append_only BEFORE DELETE OR UPDATE ON public.screenshot_uploads FOR EACH ROW EXECUTE FUNCTION public.reject_evidence_modification();


--
-- Name: statement_checkpoints statement_checkpoints_are_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER statement_checkpoints_are_append_only BEFORE DELETE OR UPDATE ON public.statement_checkpoints FOR EACH ROW EXECUTE FUNCTION public.reject_evidence_modification();


--
-- Name: bank_accounts bank_accounts_ledger_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bank_accounts
    ADD CONSTRAINT bank_accounts_ledger_account_id_fkey FOREIGN KEY (ledger_account_id) REFERENCES public.ledger_accounts(id);


--
-- Name: import_batch_coverage import_batch_coverage_bank_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_batch_coverage
    ADD CONSTRAINT import_batch_coverage_bank_account_id_fkey FOREIGN KEY (bank_account_id) REFERENCES public.bank_accounts(id);


--
-- Name: import_batch_coverage import_batch_coverage_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_batch_coverage
    ADD CONSTRAINT import_batch_coverage_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.import_batches(id);


--
-- Name: import_review_items import_review_items_bank_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_review_items
    ADD CONSTRAINT import_review_items_bank_account_id_fkey FOREIGN KEY (bank_account_id) REFERENCES public.bank_accounts(id);


--
-- Name: import_review_items import_review_items_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_review_items
    ADD CONSTRAINT import_review_items_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.import_batches(id);


--
-- Name: import_review_items import_review_items_raw_bank_row_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_review_items
    ADD CONSTRAINT import_review_items_raw_bank_row_id_fkey FOREIGN KEY (raw_bank_row_id) REFERENCES public.raw_bank_rows(id);


--
-- Name: import_review_items import_review_items_related_raw_bank_row_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_review_items
    ADD CONSTRAINT import_review_items_related_raw_bank_row_id_fkey FOREIGN KEY (related_raw_bank_row_id) REFERENCES public.raw_bank_rows(id);


--
-- Name: journal_entries journal_entries_reverses_entry_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entries
    ADD CONSTRAINT journal_entries_reverses_entry_id_fkey FOREIGN KEY (reverses_entry_id) REFERENCES public.journal_entries(id);


--
-- Name: journal_entry_evidence journal_entry_evidence_entry_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entry_evidence
    ADD CONSTRAINT journal_entry_evidence_entry_id_fkey FOREIGN KEY (entry_id) REFERENCES public.journal_entries(id);


--
-- Name: journal_entry_evidence journal_entry_evidence_raw_bank_row_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entry_evidence
    ADD CONSTRAINT journal_entry_evidence_raw_bank_row_id_fkey FOREIGN KEY (raw_bank_row_id) REFERENCES public.raw_bank_rows(id);


--
-- Name: journal_lines journal_lines_entry_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_lines
    ADD CONSTRAINT journal_lines_entry_id_fkey FOREIGN KEY (entry_id) REFERENCES public.journal_entries(id);


--
-- Name: journal_lines journal_lines_ledger_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_lines
    ADD CONSTRAINT journal_lines_ledger_account_id_fkey FOREIGN KEY (ledger_account_id) REFERENCES public.ledger_accounts(id);


--
-- Name: opening_balances opening_balances_bank_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_balances
    ADD CONSTRAINT opening_balances_bank_account_id_fkey FOREIGN KEY (bank_account_id) REFERENCES public.bank_accounts(id);


--
-- Name: opening_balances opening_balances_entry_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_balances
    ADD CONSTRAINT opening_balances_entry_id_fkey FOREIGN KEY (entry_id) REFERENCES public.journal_entries(id);


--
-- Name: people people_ledger_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.people
    ADD CONSTRAINT people_ledger_account_id_fkey FOREIGN KEY (ledger_account_id) REFERENCES public.ledger_accounts(id);


--
-- Name: provisional_resolutions provisional_resolutions_raw_bank_row_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provisional_resolutions
    ADD CONSTRAINT provisional_resolutions_raw_bank_row_id_fkey FOREIGN KEY (raw_bank_row_id) REFERENCES public.raw_bank_rows(id);


--
-- Name: provisional_resolutions provisional_resolutions_screenshot_row_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provisional_resolutions
    ADD CONSTRAINT provisional_resolutions_screenshot_row_id_fkey FOREIGN KEY (screenshot_row_id) REFERENCES public.screenshot_rows(id);


--
-- Name: provisional_resolutions provisional_resolutions_superseded_by_screenshot_row_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provisional_resolutions
    ADD CONSTRAINT provisional_resolutions_superseded_by_screenshot_row_id_fkey FOREIGN KEY (superseded_by_screenshot_row_id) REFERENCES public.screenshot_rows(id);


--
-- Name: raw_bank_rows raw_bank_rows_bank_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.raw_bank_rows
    ADD CONSTRAINT raw_bank_rows_bank_account_id_fkey FOREIGN KEY (bank_account_id) REFERENCES public.bank_accounts(id);


--
-- Name: raw_bank_rows raw_bank_rows_first_seen_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.raw_bank_rows
    ADD CONSTRAINT raw_bank_rows_first_seen_batch_id_fkey FOREIGN KEY (first_seen_batch_id) REFERENCES public.import_batches(id);


--
-- Name: screenshot_entry_evidence screenshot_entry_evidence_entry_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screenshot_entry_evidence
    ADD CONSTRAINT screenshot_entry_evidence_entry_id_fkey FOREIGN KEY (entry_id) REFERENCES public.journal_entries(id);


--
-- Name: screenshot_entry_evidence screenshot_entry_evidence_screenshot_row_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screenshot_entry_evidence
    ADD CONSTRAINT screenshot_entry_evidence_screenshot_row_id_fkey FOREIGN KEY (screenshot_row_id) REFERENCES public.screenshot_rows(id);


--
-- Name: screenshot_rows screenshot_rows_bank_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screenshot_rows
    ADD CONSTRAINT screenshot_rows_bank_account_id_fkey FOREIGN KEY (bank_account_id) REFERENCES public.bank_accounts(id);


--
-- Name: screenshot_rows screenshot_rows_upload_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screenshot_rows
    ADD CONSTRAINT screenshot_rows_upload_id_fkey FOREIGN KEY (upload_id) REFERENCES public.screenshot_uploads(id);


--
-- Name: screenshot_uploads screenshot_uploads_bank_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.screenshot_uploads
    ADD CONSTRAINT screenshot_uploads_bank_account_id_fkey FOREIGN KEY (bank_account_id) REFERENCES public.bank_accounts(id);


--
-- Name: statement_checkpoints statement_checkpoints_bank_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.statement_checkpoints
    ADD CONSTRAINT statement_checkpoints_bank_account_id_fkey FOREIGN KEY (bank_account_id) REFERENCES public.bank_accounts(id);


--
-- PostgreSQL database dump complete
--

\unrestrict dbmate


--
-- Dbmate schema migrations
--

INSERT INTO public.schema_migrations (version) VALUES
    ('20260922210000'),
    ('20260923120000'),
    ('20260924090000'),
    ('20260925090000'),
    ('20260926090000'),
    ('20260927090000'),
    ('20260928090000');
