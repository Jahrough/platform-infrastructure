#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo "Usage: $0 <rds-host:port> <master-secret-arn> <catalog-secret-name> <search-secret-name> <aws-region>" >&2
  exit 2
fi

for command in aws jq psql python3; do
  command -v "$command" >/dev/null || {
    echo "Required command not found: $command" >&2
    exit 1
  }
done

rds_endpoint=$1
master_secret_arn=$2
catalog_secret_name=$3
search_secret_name=$4
aws_region=$5

read -r -s -p "Product catalog database password: " catalog_password
printf '\n'
read -r -s -p "Confirm catalog password: " catalog_password_confirm
printf '\n'
[[ "$catalog_password" == "$catalog_password_confirm" ]] || {
  echo "Catalog passwords do not match." >&2
  exit 1
}
(( ${#catalog_password} >= 16 )) || {
  echo "Catalog password must be at least 16 characters." >&2
  exit 1
}

read -r -s -p "Product search database password: " search_password
printf '\n'
read -r -s -p "Confirm search password: " search_password_confirm
printf '\n'
[[ "$search_password" == "$search_password_confirm" ]] || {
  echo "Search passwords do not match." >&2
  exit 1
}
(( ${#search_password} >= 16 )) || {
  echo "Search password must be at least 16 characters." >&2
  exit 1
}

master_secret=$(aws secretsmanager get-secret-value \
  --region "$aws_region" \
  --secret-id "$master_secret_arn" \
  --query SecretString \
  --output text)
master_username=$(jq -er '.username' <<<"$master_secret")
master_password=$(jq -er '.password' <<<"$master_secret")

temp_dir=$(mktemp -d)
chmod 700 "$temp_dir"
trap 'rm -rf "$temp_dir"' EXIT

export CATALOG_PASSWORD="$catalog_password"
export SEARCH_PASSWORD="$search_password"
export TEMPLATE_PATH="$PWD/scripts/create-app-db-user.sql"
export RENDERED_SQL="$temp_dir/create-app-db-user.sql"
export CATALOG_SECRET_FILE="$temp_dir/catalog-secret.json"
export SEARCH_SECRET_FILE="$temp_dir/search-secret.json"
export RDS_ENDPOINT="$rds_endpoint"

python3 <<'PY'
import json
import os
from pathlib import Path

def sql_literal(value):
    return value.replace("'", "''")

template = Path(os.environ["TEMPLATE_PATH"]).read_text()
template = template.replace(
    "__CATALOG_PASSWORD__", sql_literal(os.environ["CATALOG_PASSWORD"])
).replace("__SEARCH_PASSWORD__", sql_literal(os.environ["SEARCH_PASSWORD"]))
Path(os.environ["RENDERED_SQL"]).write_text(template)

endpoint = os.environ["RDS_ENDPOINT"]
Path(os.environ["CATALOG_SECRET_FILE"]).write_text(json.dumps({
    "username": "product_catalog_app",
    "password": os.environ["CATALOG_PASSWORD"],
}))
Path(os.environ["SEARCH_SECRET_FILE"]).write_text(json.dumps({
    "url": f"jdbc:postgresql://{endpoint}/product_search",
    "username": "product_search_app",
    "password": os.environ["SEARCH_PASSWORD"],
}))
PY
chmod 600 "$temp_dir"/*

PGPASSWORD="$master_password" psql \
  --no-password \
  --no-psqlrc \
  --set ON_ERROR_STOP=1 \
  --host="${rds_endpoint%:*}" \
  --port="${rds_endpoint##*:}" \
  --username="$master_username" \
  --dbname=product_catalog \
  --file="$RENDERED_SQL"

aws secretsmanager put-secret-value \
  --region "$aws_region" \
  --secret-id "$catalog_secret_name" \
  --secret-string "file://$CATALOG_SECRET_FILE" >/dev/null
aws secretsmanager put-secret-value \
  --region "$aws_region" \
  --secret-id "$search_secret_name" \
  --secret-string "file://$SEARCH_SECRET_FILE" >/dev/null

unset catalog_password catalog_password_confirm search_password search_password_confirm
unset master_password master_secret
echo "Database roles created and application credentials stored in Secrets Manager."
