-- migrate:up

-- A small job queue (Phase 7, DECISIONS D070). Workers claim a due job with
-- FOR UPDATE SKIP LOCKED, so two of them never run the same one.
CREATE TABLE jobs (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('run_checks')),
  run_at TIMESTAMPTZ NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('queued', 'running', 'succeeded', 'failed')),
  attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  -- Set exactly while a worker holds the job; a job held too long is
  -- assumed to belong to a worker that died, and goes back in the queue.
  locked_at TIMESTAMPTZ,
  finished_at TIMESTAMPTZ,
  last_error TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK ((status = 'running') = (locked_at IS NOT NULL))
);

CREATE INDEX jobs_due_idx ON jobs (run_at) WHERE status = 'queued';

-- At most one pending job of each kind, so a recurring job can't pile up
-- however many servers are running.
CREATE UNIQUE INDEX jobs_one_pending_per_kind ON jobs (kind) WHERE status IN ('queued', 'running');

-- What the recurring checks found. Each check reports a set of reminders;
-- one that is still true stays open (and keeps being updated), one that no
-- longer is true is resolved, and a person can dismiss one without
-- resolving the cause.
CREATE TABLE reminders (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('statement_missing', 'provisional_stale', 'due_soon')),
  -- What the reminder is about, stable across runs (an account's last 4
  -- digits, or a due date and the day it falls on).
  subject TEXT NOT NULL CHECK (subject <> ''),
  message TEXT NOT NULL CHECK (message <> ''),
  detected_at TIMESTAMPTZ NOT NULL,
  resolved_at TIMESTAMPTZ,
  dismissed_at TIMESTAMPTZ
);

-- One open reminder per (kind, subject): a check reporting the same thing
-- twice updates the open one instead of adding another.
CREATE UNIQUE INDEX reminders_one_open_per_subject ON reminders (kind, subject) WHERE resolved_at IS NULL;

-- "The Visa payment is due on the 15th": a monthly date to be reminded of.
CREATE TABLE due_dates (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  label TEXT NOT NULL CHECK (btrim(label) <> ''),
  -- Months that are shorter use their last day.
  day_of_month INTEGER NOT NULL CHECK (day_of_month BETWEEN 1 AND 31),
  -- Remind this many days ahead.
  warn_days INTEGER NOT NULL DEFAULT 5 CHECK (warn_days BETWEEN 0 AND 28),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- migrate:down

DROP TABLE due_dates;
DROP TABLE reminders;
DROP TABLE jobs;
