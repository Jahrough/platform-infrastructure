#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONNECT_URL="http://localhost:8083"
CONNECTOR_FILE="$ROOT_DIR/connectors/postgres-outbox-connector.json"
STARTUP_TIMEOUT_SECONDS="${LOCAL_STARTUP_TIMEOUT_SECONDS:-300}"

for command in docker curl jq; do
  command -v "$command" >/dev/null || {
    echo "Required command not found: $command" >&2
    exit 1
  }
done
docker compose version >/dev/null
[[ "$STARTUP_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
  echo "LOCAL_STARTUP_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
}
[[ -r "$CONNECTOR_FILE" ]] || {
  echo "Connector config is not readable: $CONNECTOR_FILE" >&2
  exit 1
}
CONNECTOR_NAME="$(jq -er '.name | strings | select(length > 0)' "$CONNECTOR_FILE")"

compose=(docker compose)
if [[ -r "$ROOT_DIR/compose/.env" ]]; then
  compose+=(--env-file "$ROOT_DIR/compose/.env")
fi
compose+=(
  -f "$ROOT_DIR/compose/compose.yml"
  -f "$ROOT_DIR/compose/compose.apps.yaml"
)
"${compose[@]}" up --build --detach

wait_for_json() {
  local label="$1" url="$2" filter="$3" deadline payload
  deadline=$((SECONDS + STARTUP_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    payload="$(curl -fsS --max-time 5 "$url" 2>/dev/null || true)"
    if [[ -n "$payload" ]] && jq -e "$filter" >/dev/null 2>&1 <<<"$payload"; then
      printf '%s is ready\n' "$label"
      return 0
    fi
    sleep 5
  done
  echo "Timed out waiting for $label at $url" >&2
  return 1
}

wait_for_json \
  'Kafka Connect REST API' "$CONNECT_URL/connectors" 'type == "array"'
wait_for_json \
  'Product Catalog readiness' 'http://localhost:8080/actuator/health/readiness' '.status == "UP"'

LOCAL_CONNECT_REGISTRATION=1 \
  "$ROOT_DIR/scripts/register-outbox-connector.sh" \
  --env local --url "$CONNECT_URL" --file "$CONNECTOR_FILE"

wait_for_connector() {
  local deadline status_url status
  status_url="$CONNECT_URL/connectors/$CONNECTOR_NAME/status"
  deadline=$((SECONDS + STARTUP_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    status="$(curl -fsS --max-time 5 "$status_url" 2>/dev/null || true)"
    if [[ -n "$status" ]]; then
      if jq -e --arg name "$CONNECTOR_NAME" '
        .name == $name
        and .connector.state == "RUNNING"
        and (.tasks | length) > 0
        and all(.tasks[]; .state == "RUNNING")
      ' >/dev/null 2>&1 <<<"$status"; then
        echo "Connector $CONNECTOR_NAME and all tasks are RUNNING"
        return 0
      fi
      if jq -e '
        .connector.state == "FAILED"
        or any(.tasks[]?; .state == "FAILED")
      ' >/dev/null 2>&1 <<<"$status"; then
        echo "Connector $CONNECTOR_NAME or a task entered FAILED state:" >&2
        jq -r '
          "connector state: " + (.connector.state // "unknown"),
          (.tasks[]? | "task \(.id): \(.state // "unknown")")
        ' >&2 <<<"$status"
        return 1
      fi
    fi
    sleep 5
  done
  echo "Timed out waiting for connector $CONNECTOR_NAME and its task(s) to RUNNING" >&2
  return 1
}

wait_for_connector
echo 'Local platform stack is up; connector registration and task health verified.'
