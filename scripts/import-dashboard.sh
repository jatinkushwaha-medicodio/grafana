#!/bin/bash
# Usage: ./scripts/import-dashboard.sh <grafana-com-id> <new-uid>
# Example: ./scripts/import-dashboard.sh 11159 nodejs-application
#
# Downloads a community dashboard from grafana.com, strips its import-only
# metadata, wires it to our provisioned datasources (uid=prometheus / uid=loki),
# stamps it with our UID + tag, and drops it into grafana/dashboards/. The
# Grafana provider reloads within 10s — no container restart needed.
set -e

DASH_ID="$1"
NEW_UID="$2"

if [ -z "$DASH_ID" ] || [ -z "$NEW_UID" ]; then
  echo "Usage: $0 <grafana-com-id> <new-uid>" >&2
  exit 1
fi

cd "$(dirname "$0")/.."

RAW="/tmp/dash-${DASH_ID}.json"
OUT="grafana/dashboards/${NEW_UID}.json"

curl -sLf "https://grafana.com/api/dashboards/${DASH_ID}/revisions/latest/download" -o "$RAW"

jq --arg uid "$NEW_UID" '
  del(.__inputs, .__requires, .__elements)
  | (.. | objects | select(.datasource? == "${DS_PROMETHEUS}").datasource) |= {type:"prometheus", uid:"prometheus"}
  | (.. | objects | select((.datasource? != null) and (.datasource | type == "object") and (.datasource.uid? == "${DS_PROMETHEUS}")).datasource) |= {type:"prometheus", uid:"prometheus"}
  | (.. | objects | select(.datasource? == "${DS_LOKI}").datasource) |= {type:"loki", uid:"loki"}
  | (.. | objects | select((.datasource? != null) and (.datasource | type == "object") and (.datasource.uid? == "${DS_LOKI}")).datasource) |= {type:"loki", uid:"loki"}
  | .id = null
  | .uid = $uid
  | .tags = ((.tags // []) + ["globalcodio"] | unique)
' "$RAW" > "$OUT"

echo "Wrote $OUT"
jq '{title, uid, tags}' "$OUT"
