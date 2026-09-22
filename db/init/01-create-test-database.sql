-- Runs once, the first time the Postgres container starts with an empty volume.
-- The backend test suite uses this database; `make test` migrates it.
CREATE DATABASE reckon_test;
