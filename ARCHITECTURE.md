# Medicodio Monitoring Stack — Architecture

## Context

Observability for the Medicodio Whitefield backend
(`medicodio-nextgen-app-nodejs`, Express + PostgreSQL, no ORM, per-tenant
RLS). Today the app emits structured JSON logs to stdout via Winston
(`src/lib/logger.ts`) plus a Morgan HTTP access line per request. There is
one health endpoint (`GET /api/v1/app/health`) that pings the DB. No
`/metrics` endpoint, no historical metric retention, no team dashboards.

**Goal:** stand up a minimal, open-source, independently-deployed
monitoring stack — Prometheus + Loki + Grafana only — that covers DEV, UAT,
PROD from a single monitoring VM. Keep app-side changes small. Reuse
existing structured-log shape. No Alertmanager, node_exporter federation,
Alloy, or Tempo in Phase 1.

Runtime split:

- **DEV + UAT** → Docker on a shared VM. Monitoring lives on the same VM
  chassis as Jenkins.
- **PROD** → Azure Container Apps.
- **Logs** → direct-push from the app over HTTPS (no log shipper).
- **Metrics** → new top-level `GET /metrics` on the BE, token-gated.

Repo layout:

- Monitoring stack lives in this repo (`whitefield/monitoring/`).
- App-side changes (`/metrics` route + Winston→Loki transport +
  job-metric helper) land in `medicodio-nextgen-app-nodejs/`.

---

## Environments and what we scrape

| Env | App `/metrics` | VM `node_exporter` | DB `postgres_exporter` | Logs |
|-----|----------------|--------------------|------------------------|------|
| local | host.docker.internal:8000 | (skip) | (skip) | direct push (blank token) |
| dev | private hostname:8000 over HTTPS + bearer | private:9100 | private:9187 | direct push HTTPS + bearer |
| uat | private hostname:8000 over HTTPS + bearer | private:9100 | private:9187 | direct push HTTPS + bearer |
| prod | ACA FQDN over HTTPS + bearer + IP allowlist | — (managed by ACA) | private:9187 on companion VM | direct push HTTPS + bearer + IP allowlist |

Every series carries `env=<local|dev|uat|prod>` and `service=<app|node|postgres>`.
Dashboards + alerts filter on those two labels only — no per-tenant, per-user, per-route-raw labels.

---

## Architecture

```
                              ┌──────────────────────────┐
                              │   Monitoring VM          │
                              │                          │
                              │  docker-compose:         │
                              │  ┌────────────────────┐  │
   DEV app + node + pg ───────┼─►│ prometheus (scrape)│  │
   UAT app + node + pg ───────┤  └─────────┬──────────┘  │
   PROD app + pg      ────────┤            │             │
                              │            ▼             │
                              │  ┌────────────────────┐  │
                              │  │ grafana            │◄─┼── MS OAuth (phase 1e)
                              │  └─────────▲──────────┘  │
                              │            │             │
                              │  ┌─────────┴──────────┐  │
                              │  │ loki               │  │
                              │  └─────────▲──────────┘  │
                              └────────────┼─────────────┘
                                           │ HTTPS push
                                           │ (Winston transport, batched)
                                           │
                              ┌────────────┴──────────────┐
                              │ medicodio-nextgen-app-... │
                              │  - GET /metrics           │
                              │  - Winston push to Loki   │
                              │  - job metrics wrapper    │
                              └───────────────────────────┘
```

---

## What the stack answers

Primary question: **"is the app healthy?"** (availability, request rate,
latency, error rate, DB health, background-job health).

Secondary: **"what does the VM look like?"** (CPU / memory / disk /
uptime). Present in a dedicated dashboard, never on the front page.

---

## App-side instrumentation (Phase 1b)

Additions to `medicodio-nextgen-app-nodejs/`:

1. `prom-client` package + `GET /metrics` route with a token guard.
   Emits `process_*`, `nodejs_*` (from `collectDefaultMetrics`).
2. **One HTTP histogram** wrapped in middleware:
   `app_http_request_duration_seconds{method, route_template, status_class, env}`.
   Route template is the Express route pattern (`/api/v1/app/encounters/:id`);
   raw paths and query strings are never used as labels.
3. **Background-job wrapper** for the 9 crons in `src/jobs/index.ts`:
   `app_job_runs_total{job, outcome=success|failure}` counter and
   `app_job_last_success_timestamp_seconds{job}` gauge.
4. **`pg`-pool gauges**: `app_pg_pool_total|idle|waiting` — 5 lines
   around the existing pool.
5. **Winston Loki transport** in `src/lib/logger.ts` — batched (2 s / 100
   lines), non-blocking, fail-open. Empty `LOKI_PUSH_URL` → no-op.
   Environment tag added via a `defaultMeta` merge.

New env vars on the BE side:

```
METRICS_TOKEN=            # per-env, matches Prometheus's per-env token
LOKI_PUSH_URL=            # reverse-proxied Loki (blank locally)
LOKI_TOKEN=               # matches reverse-proxy bearer (blank locally)
APP_ENV=                  # local | dev | uat | prod (matches NODE_ENV)
```

---

## Prometheus config shape

`file_sd_configs` per job, one file per env per component. Prometheus
auto-reloads target files; no restart on target adds. Bearer tokens live
in Docker Secrets (`/run/secrets/<env>_metrics_token`) so they never
appear in `/api/v1/status/config`.

Scrape interval 30 s. Retention 30 d. All metric names live under two
prefixes:

- `app_*`  — Medicodio BE (this repo owns them).
- `node_*` / `pg_*` — vendored from `node_exporter` / `postgres_exporter`.

Label cardinality caps (from the app side):
- No `userId`, `clientId`, `firmId`, `patientId`, `encounterId` as labels.
- `route_template` only; `method` restricted to 7 standard verbs.
- `status_class` bucketed to `2xx|3xx|4xx|5xx`.

---

## Loki config

Single-binary mode, filesystem storage, compactor-managed retention
(30 d). Ingestion capped (8 MB/s, 10 k streams, 256 KB/line).
Stream labels: `env`, `service`, `level` only. Everything else
(`correlationId`, `userId`, `clientId`, route, module) stays in the JSON
body, filterable via LogQL `| json`.

Grafana's Loki datasource has a derived field on `correlationId` — click a
log line, follow the trace across log entries in one query.

---

## Grafana provisioning

Everything is code:

```
grafana/
├── provisioning/
│   ├── datasources/datasources.yml    # Prometheus + Loki, uid=prometheus/loki
│   ├── dashboards/dashboards.yml      # provider → /var/lib/grafana/dashboards
│   └── alerting/
│       ├── rules.yml                  # empty for Phase 1a
│       ├── policies.yml               # per-env Teams routing (unchanged)
│       └── contact-points.yml         # teams-dev / teams-uat / teams-prod
└── dashboards/
    └── medicodio/                     # Phase 1d — hand-authored JSONs
```

`allowUiUpdates: true` — engineers can prototype in the UI, then run
`scripts/sync-all-dashboards.sh` to export back to JSON and commit.
Container restart re-applies from disk, so Git remains the source of truth.

---

## Persistence + recovery

Three named Docker volumes: `prom-data`, `loki-data`, `grafana-data`.
Survive `docker compose down`; only `-v` wipes them. Nightly tar → Azure
Blob (see README). Restore = `docker compose down && tar xzf && docker
compose up -d`.

---

## Security posture

- `/metrics` on the BE is `Public()` (no JWT) but wrapped in a token
  guard that checks `Authorization: Bearer <METRICS_TOKEN>`. Per-env
  token, rotated via env vars.
- Loki push uses `Bearer <LOKI_TOKEN>`.
- All monitoring UIs bind to `127.0.0.1`. Reach Grafana over
  Tailscale / Cloudflare Tunnel / SSH-tunnel. VM firewall opens only 22
  + tunnel port.
- Grafana: admin password from `.env`; anonymous disabled; MS OAuth
  scaffolded but off by default (Phase 1e or later).

---

## Reuse vs new

| Need | Reuse | New |
|------|-------|-----|
| Structured log shape | `src/lib/logger.ts` (Winston JSON) | — |
| Correlation IDs | `src/middleware/correlation.ts` | — |
| HTTP access log | `morgan` + Winston | — |
| Per-request duration | (morgan gives ms; histogram is new) | HTTP histogram middleware |
| `/metrics` endpoint | — | `MetricsController` + `MetricsTokenGuard` |
| Background-job runs | `cron.schedule` handlers in `src/jobs/index.ts` | wrapper helper emitting counters + last-success gauge |
| DB pool visibility | `pg` Pool object | 3 gauges around it |
| Log egress | stdout only | Winston Loki transport (~60 LOC, fail-open) |

---

## Phased plan

- **1a** (this PR): rename repo assets from GlobalCodio → Medicodio;
  delete old dashboards + alert rules; rewrite Prometheus scrape config
  for our three env split + node_exporter + postgres_exporter; wire target
  files as placeholders.
- **1b**: BE additions — `/metrics`, HTTP histogram, job wrapper, pg-pool
  gauges, Winston Loki transport.
- **1c**: environment wiring — deploy `node_exporter` on DEV/UAT VMs,
  `postgres_exporter` for each DB, fill `targets/*.yml`, confirm targets
  UP.
- **1d**: hand-author four dashboards (App Health, VM Health DEV/UAT,
  PROD App Focus, Logs Explorer). Turn on 3 alerts (job staleness, 5xx
  spike, monitoring VM disk > 80 %).
- **1e**: nightly backup cron; optional MS OAuth for Grafana; runbook.

**Phase 2 (deferred, not blocked by Phase 1):** Product Usage / Feature
Adoption analytics.

---

## Out of scope for Phase 1

- Alertmanager (Grafana's built-in alerting is sufficient).
- Tempo / distributed tracing.
- Long-term storage (Thanos / Mimir / Grafana Cloud).
- Per-tenant SLOs.
- OpenTelemetry collector (revisit only if we introduce Python/Go
  services and want a unified pipeline).

---

## Risks / notes

- **Loki push on the app hot path** (async, capped buffer). Acceptable
  now; move to Alloy or a docker-log-driver shipper if prod log rate
  climbs past ~500 lines/s.
- **Single-instance Prometheus + Loki** = SPOF. Nightly volume snapshot
  is our recovery story.
- **PROD scrape over public ingress** even with token + IP allowlist is
  more attack surface than a private VNet-peered scrape. Note for
  Phase 2 hardening.
- **Monitoring repo split** from app repo means two PRs to ship a new
  dashboard tied to a new metric. Acceptable for independent deploy.
