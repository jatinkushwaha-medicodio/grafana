# Medicodio Monitoring Stack

Open-source observability for the Medicodio Whitefield backend
(`medicodio-nextgen-app-nodejs`) across **DEV**, **UAT**, and **PROD**.

Three containers only — **Grafana + Prometheus + Loki** — running on the
Jenkins/monitoring VM. Independently deployed from the app.

Architecture: see [`ARCHITECTURE.md`](./ARCHITECTURE.md).

---

## Environments

| Env | Runtime | App scrape | Host metrics | DB metrics | Logs → Loki |
|-----|---------|------------|--------------|------------|-------------|
| DEV | VM (Docker) | `/metrics` bearer | `node_exporter:9100` | `postgres_exporter:9187` | direct push |
| UAT | VM (Docker) | `/metrics` bearer | `node_exporter:9100` | `postgres_exporter:9187` | direct push |
| PROD | Azure Container Apps | `/metrics` bearer over HTTPS | — (managed) | `postgres_exporter:9187` on companion VM | direct push over HTTPS |

Monitoring VM's own host also scraped (`node-monitoring`) so we alert on
observability-stack disk usage before it kills logging.

---

## Local bring-up (developer laptop)

```bash
cp .env.example .env
# Edit .env:
#   - set GF_ADMIN_PASSWORD
#   - set LOCAL_METRICS_TOKEN (any random string; must match METRICS_TOKEN
#     on your local BE .env)
# Leave DEV/UAT/PROD token fields blank for now.

docker compose up -d

curl -s localhost:9090/-/ready                                # Prometheus ready
curl -s localhost:3033/ready                                  # Loki ready
curl -s -u admin:$GF_ADMIN_PASSWORD localhost:3030/api/health # Grafana ok
```

Open Grafana at <http://localhost:3030>. Dashboards land in the `Medicodio`
folder; switch the `env` template variable to filter.

### Wire local BE

`prometheus/targets/app-local.yml` scrapes `host.docker.internal:8000`. To
make data flow:

1. In `medicodio-nextgen-app-nodejs/.env`:
   ```
   METRICS_TOKEN=<same value as LOCAL_METRICS_TOKEN>
   LOKI_PUSH_URL=http://host.docker.internal:3033
   LOKI_TOKEN=                # blank locally
   APP_ENV=local
   ```
2. `npm run dev` in the BE repo.
3. Hit any endpoint (e.g. `curl localhost:8000/api/v1/app/health`).
4. In Grafana → dashboards → `env=local`. Series + log lines appear ~30 s.

DEV/UAT/PROD targets stay DOWN until their `targets/*.yml` files are filled
in (see **Onboarding an environment** below).

---

## Onboarding an environment

For each of DEV / UAT / PROD:

1. **Generate a per-env scrape token** (32-byte random). Store it:
   - In this stack's `.env` as `DEV_METRICS_TOKEN` / `UAT_METRICS_TOKEN` / `PROD_METRICS_TOKEN`.
   - In the env's BE container as `METRICS_TOKEN`.
2. **Open Prometheus' egress IP** on the env's ingress / reverse proxy (allowlist).
3. **Edit `prometheus/targets/app-<env>.yml`** — replace `REPLACE_ME`.
4. **(DEV/UAT only)** deploy `node_exporter` on the VM (default port 9100)
   and `postgres_exporter` (default 9187, DATA_SOURCE_NAME points at the
   DB with a read-only user). Update `node-<env>.yml` and `pg-<env>.yml`.
5. **(PROD)** deploy `postgres_exporter` next to the monitoring VM (or a
   companion VM in the same VNet) pointed at Azure PG Flexible Server.
6. **Reload Prometheus** (no restart needed):
   ```bash
   curl -X POST http://localhost:9090/-/reload
   ```
7. **Confirm targets UP**:
   ```bash
   curl -s http://localhost:9090/api/v1/targets \
     | jq '.data.activeTargets[] | {labels:.labels,health}'
   ```

For Loki: the BE container's `LOKI_PUSH_URL` must point at a reverse proxy
in front of this stack's Loki (HTTPS + bearer). `LOKI_TOKEN` must match
whatever the proxy enforces.

---

## Verification (full path)

```bash
# 1. Metrics endpoint is reachable + token-gated
curl -s -H "Authorization: Bearer $DEV_METRICS_TOKEN" "$API_URL/metrics" \
  | grep app_http_request_duration_seconds_bucket

# 2. Logs are reaching Loki
curl -s -G http://localhost:3033/loki/api/v1/query_range \
  --data-urlencode 'query={env="dev",service="app"}' \
  --data-urlencode 'start='"$(date -u -d '5 min ago' +%s)000000000" \
  | jq '.data.result | length'
```

---

## Operating notes

- **Ports** bind to `127.0.0.1` only. Reach Grafana over Tailscale /
  Cloudflare Tunnel / SSH-tunnel, never via the VM's public IP. Front Loki
  with a reverse proxy that adds HTTPS + bearer for external pushes.
- **Volumes** (`prom-data`, `loki-data`, `grafana-data`) survive
  `docker compose down`. Use `-v` only when intentionally wiping state.
- **Retention**: Prometheus 30 d, Loki 30 d. Tune in `docker-compose.yml`
  (`--storage.tsdb.retention.time`) and `loki/loki-config.yml`
  (`limits_config.retention_period`).
- **Dashboards** are committed in `grafana/dashboards/medicodio/*.json`.
  UI edits saved back to Git via `scripts/sync-all-dashboards.sh`.
- **Schema upgrades**: bump image tags in `docker-compose.yml`, test
  locally, redeploy. Volumes survive minor version bumps; back up before
  majors.

---

## Backup (nightly cron on the monitoring VM)

```bash
docker run --rm \
  -v medicodio-monitoring_prom-data:/source:ro \
  -v medicodio-monitoring_loki-data:/source2:ro \
  -v medicodio-monitoring_grafana-data:/source3:ro \
  -v /var/backups/monitoring:/dest \
  alpine tar czf "/dest/monitoring-$(date +%F).tar.gz" -C / source source2 source3
```

Push the tarballs to Azure Blob; rotate every 7 days. Restore is a
`docker compose down`, `tar xzf …`, `docker compose up -d`.
