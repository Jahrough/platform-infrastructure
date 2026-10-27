SELECT format('CREATE ROLE product_catalog_app LOGIN PASSWORD %L', '__CATALOG_PASSWORD__')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'product_catalog_app')
\gexec
ALTER ROLE product_catalog_app LOGIN PASSWORD '__CATALOG_PASSWORD__';
GRANT CONNECT ON DATABASE product_catalog TO product_catalog_app;
GRANT USAGE, CREATE ON SCHEMA public TO product_catalog_app;

SELECT format('CREATE ROLE product_search_app LOGIN PASSWORD %L', '__SEARCH_PASSWORD__')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'product_search_app')
\gexec
ALTER ROLE product_search_app LOGIN PASSWORD '__SEARCH_PASSWORD__';
SELECT 'CREATE DATABASE product_search OWNER product_search_app'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'product_search')
\gexec
ALTER DATABASE product_search OWNER TO product_search_app;