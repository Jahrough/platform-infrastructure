#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: register-outbox-connector.sh --env <local|stage|prod> --url <connect-url> --file <connector.json>
                                    [--confirm-prod <connector-name>]
All of --env, --url and --file are required; there are no defaults.
EOF
  exit 2
}

env_name="" connector_url="" connector_file="" confirm_prod=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) env_name=${2:-}; shift 2 ;;
    --url) connector_url=${2:-}; shift 2 ;;
    --file) connector_file=${2:-}; shift 2 ;;
    --confirm-prod) confirm_prod=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$env_name" && -n "$connector_url" && -n "$connector_file" ]] || usage

die() { echo "Refusing: $*" >&2; exit 1; }

command -v curl >/dev/null || {
  echo "Required command not found: curl" >&2
  exit 1
}
command -v jq >/dev/null || {
  echo "Required command not found: jq" >&2
  exit 1
}
[[ -r "$connector_file" ]] || die "connector config is not readable: $connector_file"

connector_name=$(jq -er '.name' "$connector_file")

[[ "$connector_url" =~ ^https?://([^/:@]+)(:[0-9]+)?$ ]] ||
  die "url must be http(s)://host[:port] with no path or credentials"
host=${BASH_REMATCH[1]}

case "$env_name" in
  local)
    [[ "$host" =~ ^(localhost|127\.0\.0\.1)$ ]] ||
      die "local env only allows localhost or 127.0.0.1 (got $host)"
    [[ "${LOCAL_CONNECT_REGISTRATION:-}" == 1 ]] ||
      die "local registration requires LOCAL_CONNECT_REGISTRATION=1"
    ;;
  stage)
    [[ "$host" != *production* && "$host" == *staging* ]] ||
      die "host '$host' is not a staging endpoint"
    ;;
  prod)
    [[ "$host" == *platform-production* ]] || die "host '$host' is not a production endpoint"
    [[ "$confirm_prod" == "$connector_name" ]] || die "prod requires --confirm-prod $connector_name"
    ;;
  *) usage ;;
esac

# Credentials must be provider references, never literals.
jq -e '[.config | to_entries[] | select(.key | test("password|secret|token"; "i")) | .value | tostring
        | test("^\\$\\{(env|file):[^}]+\\}$")] | all' "$connector_file" >/dev/null ||
  die "connector config contains a literal credential; use \${env:...} references"

jq -e '.config' "$connector_file" |
  curl --fail-with-body --silent --show-error \
    --retry 12 --retry-connrefused --retry-delay 5 \
    --request PUT \
    --header 'Content-Type: application/json' \
    --data-binary @- \
    "$connector_url/connectors/$connector_name/config"
