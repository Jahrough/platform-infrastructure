#!/usr/bin/env bash
# Local-only bootstrap, run once by the postgres image on an empty data volume.
# Creates the CDC role/publication and the Search database. Cloud environments
# use scripts/create-cdc-db-user.sql and scripts/create-app-db-user.sql instead.
set -euo pipefail

: "${CDC_DATABASE_USER:?}" "${CDC_DATABASE_PASSWORD:?}"
: "${SEARCH_DATABASE_USER:?}" "${SEARCH_DATABASE_PASSWORD:?}"

psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d product_catalog \
  -v cdc_user="$CDC_DATABASE_USER" -v cdc_pw="$CDC_DATABASE_PASSWORD" \
  -v search_user="$SEARCH_DATABASE_USER" -v search_pw="$SEARCH_DATABASE_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN REPLICATION PASSWORD %L', :'cdc_user', :'cdc_pw')
\gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'search_user', :'search_pw')
\gexec
SELECT format('CREATE DATABASE product_search OWNER %I', :'search_user')
\gexec
SELECT format('GRANT USAGE ON SCHEMA public TO %I', :'cdc_user')
\gexec
-- Tables are created later by Catalog's Flyway migration (as the owner role).
SELECT format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public GRANT SELECT ON TABLES TO %I',
              current_user, :'cdc_user')
\gexec
-- The outbox table does not exist yet, so the publication covers all tables;
-- the connector narrows capture with table.include.list.
CREATE PUBLICATION debezium_product_outbox_pub FOR ALL TABLES;
SQL
