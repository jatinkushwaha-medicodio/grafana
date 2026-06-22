# Dashboards — Workflow

Source of truth = `grafana/dashboards/*.json` in git. Grafana provisioner
reads these on startup + every 10s after.

---

## Sync UI edits back to git

The whole loop:

```bash
# 1. Edit dashboard at http://localhost:3030 → click "Save dashboard" (disk icon).
#    (No save = panel reappears on refresh. Save is the persistence step.)

# 2. Export the live state into the JSON file
./scripts/export-dashboard.sh <uid>

# 3. Commit + push
git diff grafana/dashboards/<uid>.json
git add grafana/dashboards/<uid>.json
git commit -m "monitoring: <what changed>"
git push
```

Find a dashboard's UID in the URL: `http://localhost:3030/d/<uid>/<slug>`.

---

## Add a community dashboard

```bash
./scripts/import-dashboard.sh <grafana-com-id> <new-uid>
git add grafana/dashboards/<new-uid>.json
git commit -m "monitoring: add <name> (<id>)"
git push
```

Browse IDs at <https://grafana.com/grafana/dashboards/>. The script
sanitises the JSON (strips import metadata, wires our `prometheus` / `loki`
datasource UIDs, tags with `globalcodio`).

---

## Delete a dashboard

```bash
rm grafana/dashboards/<uid>.json
git commit -am "monitoring: drop <uid>"
git push
```

Provisioner cascades the deletion to live Grafana within 10s. UI-only
deletion is blocked ("provisioned dashboard cannot be deleted") — file
removal is the path.

---

## Edit the JSON directly (no UI)

```bash
$EDITOR grafana/dashboards/<uid>.json
# Save. Provisioner reloads in 10s. Verify in UI.

git diff && git commit -am "..." && git push
```

---

## Deploy

`git push` to `main` triggers Jenkins (`Jenkinsfile`):

1. Validates compose + prom + loki + dashboard JSON locally.
2. SSHes to the monitoring VM → `git pull` → `docker compose up -d`.
3. Smoke-tests Prometheus / Loki / Grafana `/health`.

Named volumes (`prom-data`, `loki-data`, `grafana-data`) survive every
deploy — 30d of metrics, logs, and Grafana state persist.

---

## Rules

- **UID**: lowercase kebab-case, unique. Never change after a dashboard ships.
- **`id` field**: always `null` in committed JSON.
- **Tags**: include `"globalcodio"`.
- **Datasource refs**: object form, never `${DS_*}` placeholders.
- **Template vars**: use `env=~"$env"` so one variable filters every panel.
- **Do NOT** run `grafanactl resources pull` — writes incompatible k8s
  format. Use `./scripts/export-dashboard.sh`.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Panel reappears after delete | Forgot to click "Save dashboard" | Delete → Save → re-export |
| "No data" in every panel | Metric names don't match prom-client | Edit panel → check PromQL against `http://localhost:9090/graph` |
| "Datasource ${DS_PROMETHEUS} not found" | Import didn't sanitise | Re-run `./scripts/import-dashboard.sh` |
| Duplicate UID error | Two files share `.uid` | `jq -r '.uid' grafana/dashboards/*.json \| sort \| uniq -d` |
| UI edit lost after restart | Forgot to export before container recreate | Re-edit, export immediately |
| `Dashboard/` or `Folder/` subdirs appeared | Ran `grafanactl pull` by mistake | `rm -rf grafana/dashboards/Dashboard grafana/dashboards/Folder` |
can 