-- migrate:up

-- Rules are now written in the rule language (Phase 7, DECISIONS D067): one
-- line of text per rule, parsed by the backend. The text is stored as
-- written back by the parser (canonical spacing and case), so the same rule
-- can't be saved twice. Rules are configuration, not financial records, so
-- they may be deleted.
CREATE TABLE posting_rules (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  rule_text TEXT NOT NULL CHECK (btrim(rule_text) <> ''),
  -- Lower runs first; ties go to the older rule.
  priority INTEGER NOT NULL DEFAULT 100,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (rule_text)
);

-- The old "description contains X -> account" rules, in the new language.
-- A backslash or a quote inside the text is escaped the way the language
-- reads it.
INSERT INTO posting_rules (rule_text, priority, created_at)
SELECT 'when description contains "'
         || replace(replace(r.description_contains, E'\\', E'\\\\'), '"', E'\\"')
         || '" then categorize ' || lower(a.name),
       r.priority,
       r.created_at
FROM categorization_rules r
JOIN ledger_accounts a ON a.id = r.ledger_account_id
ORDER BY r.id;

DROP TABLE categorization_rules;

-- migrate:down

CREATE TABLE categorization_rules (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  description_contains TEXT NOT NULL
    CHECK (description_contains <> '' AND description_contains = upper(description_contains)),
  ledger_account_id BIGINT NOT NULL REFERENCES ledger_accounts (id),
  priority INTEGER NOT NULL DEFAULT 100,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (description_contains)
);

-- Rules written in the new language can't all be expressed in the old
-- format, so none are carried back: going down loses them.
DROP TABLE posting_rules;
