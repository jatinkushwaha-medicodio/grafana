#!/bin/bash
# Usage: ./scripts/export-dashboard.sh <uid> [outfile]
# Example: ./scripts/export-dashboard.sh api-overview
#
# Pulls the live dashboard from the running Grafana via its HTTP API and
# overwrites grafana/dashboards/<uid>.json. The provisioner reloads within
# 10s. Commit + push the diff to propagate to UAT/PROD VMs.
#
# Requires GF_ADMIN_USER + GF_ADMIN_PASSWORD in .env (sourced automatically).
set -e

UID_ARG="$1"
if [ -z "$UID_ARG" ]; then
  echo "Usage: $0 <uid> [outfile]" >&2
  exit 1
fi

cd "$(dirname "$0")/.."

if [ -f .env ]; then
  set -a; . ./.env; set +a
fi

GF_URL="${GF_URL:-http://localhost:3030}"
OUT="${2:-grafana/dashboards/${UID_ARG}.json}"

curl -sLf -u "${GF_ADMIN_USER}:${GF_ADMIN_PASSWORD}" \
  "${GF_URL}/api/dashboards/uid/${UID_ARG}" \
  | jq '
      .dashboard
      | .id = null
      | .tags = ((.tags // []) + ["globalcodio"] | unique)
    ' \
  > "$OUT"

echo "Wrote $OUT"
jq '{title, uid, tags, version}' "$OUT"
