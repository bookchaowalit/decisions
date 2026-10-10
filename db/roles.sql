-- Roles for the decisions database. Locally a superuser runs this; on Neon
-- `decisions-db provision` creates the same roles through the migrator.
--
-- decisions_migrator  owns the schema and runs migrations only.
-- decisions_api       the API at runtime: no superuser, no BYPASSRLS, owns nothing.
-- decisions_publisher sweeps and marks the outbox across workspaces; nothing else.

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'decisions_migrator') THEN
        CREATE ROLE decisions_migrator LOGIN NOSUPERUSER NOCREATEROLE NOBYPASSRLS;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'decisions_api') THEN
        CREATE ROLE decisions_api LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOINHERIT;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'decisions_publisher') THEN
        CREATE ROLE decisions_publisher LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOINHERIT;
    END IF;
END
$$;
