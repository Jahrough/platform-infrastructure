#!/usr/bin/env bash
set -euo pipefail

connector_url=${1:-http://kafka-connect.platform-production.svc.cluster.local:8083}
connector_file=${2:-connectors/postgres-outbox-connector.json}

command -v curl >/dev/null || {
  echo "Required command not found: curl" >&2
  exit 1
}
command -v jq >/dev/null || {
  echo "Required command not found: jq" >&2
  exit 1
}
[[ -r "$connector_file" ]] || {
  echo "Connector config is not readable: $connector_file" >&2
  exit 1
}

connector_name=$(jq -er '.name' "$connector_file")
jq -e '.config' "$connector_file" |
  curl --fail-with-body --silent --show-error \
    --retry 12 --retry-connrefused --retry-delay 5 \
    --request PUT \
    --header 'Content-Type: application/json' \
    --data-binary @- \
    "$connector_url/connectors/$connector_name/config"
