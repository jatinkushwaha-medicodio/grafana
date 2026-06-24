#!/bin/bash
# Usage: ./scripts/sync-all-dashboards.sh
# Pulls every dashboard JSON tracked under grafana/dashboards/ from the running
# Grafana and overwrites the file in place. Preserves the folder layout
# (common/, services/, …). New UI-only dashboards (no JSON in repo yet) are
# NOT picked up — add them once via ./scripts/export-dashboard.sh <uid>.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -f .env ]; then
  set -a; . ./.env; set +a
fi

GF_URL="${GF_URL:-http://localhost:3030}"

if [ -z "${GF_ADMIN_USER:-}" ] || [ -z "${GF_ADMIN_PASSWORD:-}" ]; then
  echo "GF_ADMIN_USER / GF_ADMIN_PASSWORD missing — set in .env" >&2
  exit 1
fi

changed=0
unchanged=0
missing=0

for file in $(find grafana/dashboards -type f -name '*.json' | sort); do
  uid=$(jq -r '.uid' "$file")
  if [ -z "$uid" ] || [ "$uid" = "null" ]; then
    echo "skip $file — no uid"
    continue
  fi

  tmp="$(mktemp)"
  status=$(curl -s -o "$tmp" -w "%{http_code}" \
    -u "$GF_ADMIN_USER:$GF_ADMIN_PASSWORD" \
    "$GF_URL/api/dashboards/uid/$uid")

  if [ "$status" != "200" ]; then
    echo "miss $file (uid=$uid, http=$status)"
    missing=$((missing+1))
    rm -f "$tmp"
    continue
  fi

  jq '.dashboard | .id = null | .tags = ((.tags // []) + ["globalcodio"] | unique)' "$tmp" > "$file"
  rm -f "$tmp"

  if git diff --quiet -- "$file"; then
    unchanged=$((unchanged+1))
  else
    changed=$((changed+1))
    echo "diff $file"
  fi
done

echo ""
echo "Summary: $changed changed, $unchanged unchanged, $missing missing in Grafana"
git --no-pager diff --stat grafana/dashboards/ || true
