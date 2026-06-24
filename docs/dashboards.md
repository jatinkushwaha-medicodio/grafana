# Dashboards — Workflow

Source of truth = `grafana/dashboards/**/*.json` in git. Folder layout:

```
grafana/dashboards/
├── common/        ← cross-service (Global Overview)
└── services/      ← per-service (API Overview, agent later, …)
```

Grafana provisioner reads these on startup + every 10s after.

---

## Sync UI edits back to git

After you edit + **Save** in the Grafana UI:

```bash
cd ~/code/global/global-monitoring

# Pull every tracked dashboard's latest UI state at once
./scripts/sync-all-dashboards.sh

git diff grafana/dashboards/
git commit -am "monitoring: <what changed>"
git push
```

`sync-all-dashboards.sh` walks every JSON under `grafana/dashboards/**`, pulls
the latest from local Grafana, and overwrites the file in place. Folder layout
preserved. New UI-only dashboards (no file in git yet) are **not** picked up
— use `import-dashboard.sh` once for those.

---

## Sync a single dashboard

```bash
./scripts/export-dashboard.sh <uid>
```

Find a dashboard's UID in the URL: `http://localhost:3030/d/<uid>/<slug>`.

Common UIDs:
- `service-api-overview` → `grafana/dashboards/services/api-overview.json`
- `common-global-overview` → `grafana/dashboards/common/global-overview.json`

---

## Add a community dashboard

```bash
./scripts/import-dashboard.sh <grafana-com-id> <new-uid>
mv grafana/dashboards/<new-uid>.json grafana/dashboards/services/    # or common/
git add grafana/dashboards/services/<new-uid>.json
git commit -m "monitoring: add <name> (<id>)"
git push
```

Browse IDs at <https://grafana.com/grafana/dashboards/>. The script sanitises
the JSON (strips import metadata, wires our `prometheus` / `loki` datasource
UIDs, tags with `globalcodio`).

---

## Delete a dashboard

```bash
rm grafana/dashboards/<folder>/<uid>.json
git commit -am "monitoring: drop <uid>"
git push
```

Provisioner cascades the deletion to live Grafana within 10s. UI-only
deletion is blocked ("provisioned dashboard cannot be deleted") — file
removal is the path.

---

## Edit the JSON directly (no UI)

```bash
$EDITOR grafana/dashboards/<folder>/<uid>.json
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

## Script cheat-sheet

| Command | Use when |
|---|---|
| `./scripts/sync-all-dashboards.sh` | After UI edits — pulls all tracked dashboards in one pass |
| `./scripts/export-dashboard.sh <uid>` | Pull a single dashboard |
| `./scripts/import-dashboard.sh <grafana-com-id> <uid>` | Onboard a community dashboard from grafana.com |

All three read `GF_ADMIN_USER` / `GF_ADMIN_PASSWORD` from `.env`.

---

## Rules

- **UID**: lowercase kebab-case, unique. Never change after a dashboard ships.
- **`id` field**: always `null` in committed JSON.
- **Tags**: include `"globalcodio"`.
- **Datasource refs**: object form, never `${DS_*}` placeholders.
- **Template vars**: use `env=~"$env"` so one variable filters every panel.
- **Save first.** UI edits don't persist until you click the disk icon. No save = sync sees nothing.
- **Do NOT** run `grafanactl resources pull` — writes incompatible k8s format. Use the scripts above.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `sync-all-dashboards.sh` reports `miss` for a file | Dashboard deleted in UI but file still in git | `rm grafana/dashboards/<folder>/<uid>.json` then commit |
| Panel reappears after delete | Forgot to click "Save dashboard" | Delete → Save → re-sync |
| "No data" in every panel | Metric names don't match prom-client | Edit panel → check PromQL against `http://localhost:9090/graph` |
| "Datasource ${DS_PROMETHEUS} not found" | Import didn't sanitise | Re-run `./scripts/import-dashboard.sh` |
| Duplicate UID error | Two files share `.uid` | `jq -r '.uid' grafana/dashboards/**/*.json \| sort \| uniq -d` |
| UI edit lost after restart | Forgot to sync before container recreate | Re-edit, sync immediately |
| `Dashboard/` or `Folder/` subdirs appeared | Ran `grafanactl pull` by mistake | `rm -rf grafana/dashboards/Dashboard grafana/dashboards/Folder` |
| Script fails with `GF_ADMIN_USER / GF_ADMIN_PASSWORD missing` | `.env` not loaded or unset | Check `global-monitoring/.env` has both set |
