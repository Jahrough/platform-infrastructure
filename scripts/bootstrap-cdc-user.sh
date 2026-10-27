#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "Usage: $0 <rds-host:port> <master-secret-arn> <cdc-secret-name> <aws-region>" >&2
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
cdc_secret_name=$3
aws_region=$4

read -r -s -p "Debezium database password: " cdc_password
printf '\n'
read -r -s -p "Confirm Debezium password: " cdc_password_confirm
printf '\n'
[[ "$cdc_password" == "$cdc_password_confirm" ]] || {
  echo "CDC passwords do not match." >&2
  exit 1
}
(( ${#cdc_password} >= 16 )) || {
  echo "CDC password must be at least 16 characters." >&2
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
export CDC_PASSWORD="$cdc_password"
export TEMPLATE_PATH="$PWD/scripts/create-cdc-db-user.sql"
export RENDERED_SQL="$temp_dir/create-cdc-db-user.sql"
export CDC_SECRET_FILE="$temp_dir/cdc-secret.json"

python3 <<'PY'
import json
import os
from pathlib import Path

password = os.environ["CDC_PASSWORD"].replace("'", "''")
Path(os.environ["RENDERED_SQL"]).write_text(
    Path(os.environ["TEMPLATE_PATH"]).read_text()
    .replace("__CDC_PASSWORD__", password)
)
Path(os.environ["CDC_SECRET_FILE"]).write_text(json.dumps({
    "username": "product_cdc",
    "password": os.environ["CDC_PASSWORD"],
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
  --secret-id "$cdc_secret_name" \
  --secret-string "file://$CDC_SECRET_FILE" >/dev/null

unset cdc_password cdc_password_confirm master_password master_secret
echo "CDC role created and credentials stored. Kafka Connect can now read the outbox."
