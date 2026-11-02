-- Least privilege for the running app. Run once per database, as the role that owns the tables (the one migrations
-- run as), after the migrations:
--
--   docker compose -f compose.production.yaml exec -T postgres \
--     psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 < deploy/db-roles.sql
--
-- then give the new role a password without it ever appearing in a file or the shell history:
--
--   docker compose -f compose.production.yaml exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c '\password mailbridge_app'
--
-- The app then connects as mailbridge_app (POSTGRES_USER/POSTGRES_PASSWORD of the app service); migrations keep using
-- the owner. What this buys: the app's credentials cannot change the schema, drop or disable the audit log's guard
-- triggers, truncate tables or update audit rows. A SQL injection or a stolen app password is limited to row
-- reads and writes the app already does.
--
-- Safe to run again: it only creates what is missing and grants what is missing.

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mailbridge_app') THEN
        -- LOGIN only: no superuser, no CREATEDB, no CREATEROLE, no replication, cannot bypass row security.
        CREATE ROLE mailbridge_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
    END IF;
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO mailbridge_app', current_database());
END
$$;

-- Nobody but the owner may create objects in the schema (the default since PostgreSQL 15; stated for clarity).
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO mailbridge_app;

-- Ordinary tables: the app reads and writes rows, nothing more (no TRUNCATE, REFERENCES or TRIGGER).
GRANT SELECT, INSERT, UPDATE, DELETE ON
    users, sessions, login_attempts, password_resets, user_avatars,
    mail_accounts, emails, email_bodies, outgoing_messages
TO mailbridge_app;

-- The audit log: read and append. DELETE is allowed only for what the guard trigger lets through (retention).
GRANT SELECT, INSERT, DELETE ON audit_events TO mailbridge_app;

-- Tables added by later migrations get the ordinary row privileges automatically. A migration that adds a table
-- needing less (like audit_events) revokes the extra privileges itself.
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO mailbridge_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO mailbridge_app;
