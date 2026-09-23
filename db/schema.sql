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
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


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
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: journal_entries_occurred_on_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX journal_entries_occurred_on_idx ON public.journal_entries USING btree (occurred_on);


--
-- Name: journal_lines_entry_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX journal_lines_entry_id_idx ON public.journal_lines USING btree (entry_id);


--
-- Name: journal_lines_ledger_account_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX journal_lines_ledger_account_id_idx ON public.journal_lines USING btree (ledger_account_id);


--
-- Name: journal_entries journal_entries_are_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER journal_entries_are_append_only BEFORE DELETE OR UPDATE ON public.journal_entries FOR EACH ROW EXECUTE FUNCTION public.reject_journal_modification();


--
-- Name: journal_entries journal_entries_cannot_be_truncated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER journal_entries_cannot_be_truncated BEFORE TRUNCATE ON public.journal_entries FOR EACH STATEMENT EXECUTE FUNCTION public.reject_journal_modification();


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
-- Name: journal_entries journal_entries_reverses_entry_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entries
    ADD CONSTRAINT journal_entries_reverses_entry_id_fkey FOREIGN KEY (reverses_entry_id) REFERENCES public.journal_entries(id);


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
-- PostgreSQL database dump complete
--

\unrestrict dbmate


--
-- Dbmate schema migrations
--

INSERT INTO public.schema_migrations (version) VALUES
    ('20260922210000');
