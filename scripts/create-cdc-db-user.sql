SELECT format('CREATE ROLE product_cdc LOGIN REPLICATION PASSWORD %L', '__CDC_PASSWORD__')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'product_cdc')
\gexec
ALTER ROLE product_cdc LOGIN REPLICATION PASSWORD '__CDC_PASSWORD__';
GRANT rds_replication TO product_cdc;
GRANT CONNECT ON DATABASE product_catalog TO product_cdc;
GRANT USAGE ON SCHEMA public TO product_cdc;
GRANT SELECT ON TABLE public.outbox TO product_cdc;

SELECT 'CREATE PUBLICATION debezium_product_outbox_pub FOR TABLE public.outbox'
WHERE NOT EXISTS (
  SELECT 1 FROM pg_publication
  WHERE pubname = 'debezium_product_outbox_pub'
)
\gexec