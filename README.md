# GlobalCodio Monitoring Stack

Open-source observability for the `apps/api` service across Dev, UAT, and Prod.
Three containers only — **Grafana + Prometheus + Loki** — running on a single VM
and developed/deployed independently from the application.

Architecture: see [`ARCHITECTURE.md`](./ARCHITECTURE.md).

---

## Local bring-up

```bash
cp .env.example .env
# Edit .env:
#   - set GF_ADMIN_PASSWORD
#   - set LOCAL_METRICS_TOKEN to any random string (must match METRICS_TOKEN
#     on your local apps/api .env)
# Leave DEV/UAT/PROD token fields blank for now.

docker compose up -d

curl -s localhost:9090/-/ready                                # Prometheus ready
curl -s localhost:3100/ready                                  # Loki ready
curl -s -u admin:$GF_ADMIN_PASSWORD localhost:3030/api/health # Grafana ok
```

Open Grafana at <http://localhost:3030>. The provisioned `API Overview` dashboard
sits in the `GlobalCodio` folder; switch the `env` template variable to filter.

### Wiring your local API

`prometheus/targets/local.yml` scrapes `host.docker.internal:3001`. To make
data flow:

1. In `apps/api/.env` set `METRICS_TOKEN=<same value as LOCAL_METRICS_TOKEN>`,
   `LOKI_PUSH_URL=http://host.docker.internal:3100`, `LOKI_TOKEN=` (blank — no
   reverse proxy in front of local Loki), `APP_ENV=local`.
2. `pnpm nx serve api`.
3. Hit any endpoint (e.g. `curl localhost:3001/v1/health/live`).
4. In Grafana → `API Overview` → set `env=local`. Series + log lines should appear
   within ~30s.

DEV/UAT/PROD targets show DOWN until their `targets/*.yml` files are filled in
(see *Onboarding an environment* below).

---

## Onboarding an environment

For each of Dev / UAT / Prod:

1. **Generate a per-env scrape token** (32-byte random). Store it:
   - In this stack's `.env` as `DEV_METRICS_TOKEN` / `UAT_METRICS_TOKEN` / `PROD_METRICS_TOKEN`.
   - In the env's API container as `METRICS_TOKEN`.
2. **Open Prometheus' egress IP** on the env's ingress / reverse proxy (allowlist).
3. **Edit `prometheus/targets/<env>.yml`** — replace `REPLACE_ME` with the real
   host:port. Labels (`env`, `service`, `region`) stay as-is.
4. **Reload Prometheus** (no restart needed):
   ```bash
   curl -X POST http://localhost:9090/-/reload
   ```
5. **Confirm the target is UP**:
   ```bash
   curl -s http://localhost:9090/api/v1/targets \
     | jq '.data.activeTargets[] | {labels:.labels,health}'
   ```

For Loki: the API container's `LOKI_PUSH_URL` must point at a reverse proxy in
front of this stack's Loki (HTTPS + bearer). `LOKI_TOKEN` must match whatever
the proxy enforces.

---

## Verification (full path)

```bash
# 1. Metrics endpoint is reachable + token-gated
curl -s -H "Authorization: Bearer $DEV_METRICS_TOKEN" "$API_URL/metrics" \
  | grep api_http_request_duration_seconds_bucket

# 2. Logs are reaching Loki
curl -s -G http://localhost:3100/loki/api/v1/query_range \
  --data-urlencode 'query={env="dev",service="api"}' \
  --data-urlencode 'start='"$(date -u -d '5 min ago' +%s)000000000" \
  | jq '.data.result | length'
```

---

## Operating notes

- **Ports** bind to `127.0.0.1` only. Reach Grafana over Tailscale / Cloudflare
  Tunnel / SSH-tunnel, never via the VM's public IP. Front Loki with a reverse
  proxy that adds HTTPS + bearer for external pushes.
- **Volumes** (`prom-data`, `loki-data`, `grafana-data`) survive
  `docker compose down`. Use `-v` only when intentionally wiping state.
- **Retention**: Prometheus 30d, Loki 30d. Tune in
  `docker-compose.yml` (`--storage.tsdb.retention.time`) and
  `loki/loki-config.yml` (`limits_config.retention_period`).
- **Dashboards** are committed in `grafana/dashboards/*.json`. UI edits are
  overwritten on container restart — change the JSON, not the live UI.
- **Schema upgrades**: bump image tags in `docker-compose.yml`, test locally,
  redeploy. Volumes survive minor version bumps; back up before majors.

---

## Backup (recommended)

A nightly cron on the VM:

```bash
docker run --rm \
  -v globalcodio-monitoring_prom-data:/source:ro \
  -v globalcodio-monitoring_loki-data:/source2:ro \
  -v globalcodio-monitoring_grafana-data:/source3:ro \
  -v /var/backups/monitoring:/dest \
  alpine tar czf "/dest/monitoring-$(date +%F).tar.gz" -C / source source2 source3
```

Push the tarballs to Azure Blob; rotate every 7 days. Restore is a
`docker compose down`, `tar xzf …`, `docker compose up -d`.
