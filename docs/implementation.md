# Medicodio Monitoring — Implementation Snapshot

Captures what was actually built, not the aspirational plan. Written after
Phase 1a–1d landed and DEV was verified end-to-end. Read this before
extending or debugging the stack.

Last updated: 2026-08-28.

---

## 1. Scope shipped

| Env | App metrics | App logs | VM metrics | DB metrics |
|-----|-------------|----------|------------|------------|
| local (developer laptop) | ✅ | ✅ | ❌ (Docker Desktop VM would report, useless) | ❌ (deferred) |
| dev (`api.dev.medicodio.ai`) | ✅ | ✅ (via app-side Loki push) | ✅ (node_exporter on same VM) | ❌ (deferred) |
| uat | ⏸ commented out in compose + Prometheus (re-enable when ready) | ⏸ | ⏸ | ❌ |
| prod (ACA) | ⏸ commented out (re-enable when ACA ingress + tokens wired) | ⏸ | ❌ (managed by ACA) | ❌ |

Everything runs on a single Ubuntu VM: **`Medicodio-UAT-DEV`** (RG
`Medicodio2.0`). Same VM already hosts the DEV + UAT app containers.

---

## 2. Runtime layout on the VM

```
┌────────────────────── Medicodio-UAT-DEV (Ubuntu, 2 vCPU, 7.7 GB RAM, 29 GB disk) ──────────────────────┐
│                                                                                                        │
│  ┌────────────────────────────────────────────────────────────────────────────┐                        │
│  │  App containers (managed by app-deploy Jenkins pipeline)                   │                        │
│  │    - Medicodio BE (dev)  → :8000  NODE_ENV=dev                             │                        │
│  │    - Medicodio BE (uat)  → :8001  NODE_ENV=uat                             │                        │
│  └────────────────────────────────────────────────────────────────────────────┘                        │
│                                                                                                        │
│  ┌───────────── medicodio-monitoring (compose project, single bridge network) ─────────────┐           │
│  │                                                                                          │           │
│  │   ┌──────────────────────┐   ┌──────────────────────┐   ┌──────────────────────┐        │           │
│  │   │ monitoring-prometheus │   │ monitoring-loki       │   │ monitoring-grafana    │        │           │
│  │   │ prom/prometheus:2.55 │   │ grafana/loki:main-550 │   │ grafana/grafana:12.0 │        │           │
│  │   │ 127.0.0.1:9090       │   │ 127.0.0.1:3033        │   │ 127.0.0.1:3030       │        │           │
│  │   │ /prometheus (volume) │   │ /loki (volume)        │   │ /var/lib/grafana     │        │           │
│  │   │ 7d retention         │   │ 7d retention          │   │ sqlite DB in volume  │        │           │
│  │   └──────────────────────┘   └──────────────────────┘   └──────────────────────┘        │           │
│  │                                                                                          │           │
│  │   ┌──────────────────────────────────────────────────────────────────────────┐           │           │
│  │   │ monitoring-node-exporter  (profile: vm — only started on VM, not local)  │           │           │
│  │   │ prom/node-exporter:1.8.2   pid: host, /:/host:ro,rslave                   │           │           │
│  │   │ 127.0.0.1:9100                                                            │           │           │
│  │   └──────────────────────────────────────────────────────────────────────────┘           │           │
│  │                                                                                          │           │
│  │   Shared network: `medicodio-monitoring_monitoring` (bridge)                             │           │
│  │   Compose DNS: containers resolve each other by service name                             │           │
│  │   All UI ports bound to 127.0.0.1 — external access = future reverse proxy               │           │
│  └──────────────────────────────────────────────────────────────────────────────────────────┘           │
│                                                                                                        │
└────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

Traffic flow:

1. **Metrics scrape** — Prometheus polls `http://host.docker.internal:8000/metrics`
   (dev BE) every 30 s with `Authorization: Bearer <DEV_METRICS_TOKEN>`. Same
   for uat once re-enabled.
2. **Host scrape** — Prometheus polls `http://node-exporter:9100/metrics`
   (compose-internal DNS) for VM CPU/memory/disk.
3. **Logs** — dev BE Winston transport POSTs batched log lines to
   `http://host.docker.internal:3033/loki/api/v1/push`. No token locally.
4. **Grafana** — reads Prometheus + Loki via compose-internal DNS
   (`http://prometheus:9090`, `http://loki:3100`).

---

## 3. Backend changes (`medicodio-nextgen-app-nodejs/`)

All additive — no route renamed, no schema touched. The changes:

### 3.1 New dependencies

`package.json`:
```
prom-client        ^15.1.3
winston-transport  ^4.9.0    (declared explicitly, previously transitive via winston)
```

### 3.2 New env vars (`src/config/env.ts`)

```ts
METRICS_TOKEN: z.string().default(''),
LOKI_PUSH_URL: z.string().default(''),
LOKI_TOKEN:    z.string().default(''),
```

Env tag is **derived from `NODE_ENV`, not from a separate `APP_ENV`**. See
`src/lib/metrics.ts`:
```ts
export const envTag = env.NODE_ENV === 'production' ? 'prod' : env.NODE_ENV;
```
So DEV BE with `NODE_ENV=dev` → `env="dev"` on every metric + log line.

### 3.3 `src/lib/metrics.ts` (new)

Owns the Prometheus registry:

- `registry` — the `Registry` used by everything.
- Default labels stamped on every metric: `{service, env}`.
- `collectDefaultMetrics({ register: registry, prefix: 'app_' })` — Node.js
  runtime metrics under `app_*`.
- `httpDuration` — `Histogram`, name `app_http_request_duration_seconds`,
  labels `{method, route, status_class}`, buckets [10 ms → 10 s].
- `jobRuns` — `Counter`, name `app_job_runs_total`, labels `{job, outcome}`.
- `jobLastSuccess` — `Gauge`, name `app_job_last_success_timestamp_seconds`,
  label `{job}`.
- `envTag` re-exported so logger + Loki transport share the same tag.

### 3.4 HTTP histogram middleware (`src/server.ts`)

Added right after `correlationMiddleware`. On every response finish:

- Duration = `process.hrtime.bigint` delta / 1e9 (nanosecond precision, no
  Date allocation on hot path).
- Route = `req.baseUrl + req.route.path` if router matched, else `unknown`
  (middleware-rejected requests). Uses mount prefix so two routers sharing a
  template don't collide.
- Status class = `${floor(status/100)}xx`.
- Observed on the histogram.

### 3.5 `GET /metrics` route (`src/server.ts`)

- Public, not under `/api`.
- If `METRICS_TOKEN` env is blank → 404 (endpoint hidden).
- Token check via `crypto.timingSafeEqual` to eliminate the length/prefix
  timing channel that plain `!==` would leak.
- Returns `registry.contentType` + `registry.metrics()` (Prometheus text
  format).

### 3.6 Morgan filter (`src/server.ts`)

Morgan HTTP access log skips `req.url === '/metrics'` so Prometheus's own
30 s scrape doesn't spam Loki with access-log noise.

### 3.7 Job wrappers (`src/jobs/index.ts`)

Original 8 cron blocks preserved verbatim — **no restructure**. For each,
a `.then()` clause was inserted before the existing `.catch()`, plus a
counter bump inside `.catch()`:

```ts
slaChecker()
  .then(() => {
    jobRuns.labels('sla_checker', 'success').inc();
    jobLastSuccess.labels('sla_checker').set(Date.now() / 1000);
  })
  .catch((err) => {
    jobRuns.labels('sla_checker', 'failure').inc();
    logger.error('SLA checker failed', ...);
  })
  .finally(...);
```

Applied to all 8 jobs. In-flight guards, PROD-only gates, comments —
unchanged. Net diff: **+41 / −0 LOC**.

Jobs stay OFF on DEV + UAT (`JOBS_ENABLED=false` by env default). Only PROD
runs them, so `app_job_*` metrics stay empty on dev/uat dashboards — the
correct signal.

### 3.8 `src/lib/loki-transport.ts` (new)

Custom Winston transport, minimal Loki push protocol:

- On construct: reads `LOKI_PUSH_URL`, `LOKI_TOKEN`, `envTag`,
  `SERVICE_NAME`. Sets `service` + `env` as Loki stream labels. Kicks off a
  `setInterval` flush every 2 s (unref'd — won't block process exit).
- On `log(info, cb)`: pushes `[timestampNs, jsonLine]` into an in-memory
  queue. Cap 1000 entries. If cap reached, silently drop overflow — never
  block the request path. Flushes early when queue ≥ 100 lines.
- Flush is **serialized** via `this.flushing: Promise<void> | null`. A
  size-triggered flush can't race an interval flush — matters because older
  Loki versions reject out-of-order writes per stream. Modern Loki accepts
  them, but the serialization is a defence-in-depth.
- On success: nothing. On failure: warn-once to `console.warn` and drop the
  batch. Never retries. `fail-open`.

### 3.9 `src/lib/logger.ts`

Two sinks:

- `Console` (unchanged) — JSON in prod, colourized in dev.
- `LokiTransport` — appended **only when `LOKI_PUSH_URL` is set**. Empty URL
  → transport not registered → zero overhead. Same code path everywhere.

`defaultMeta` extended: `{ service: env.SERVICE_NAME, env: envTag }`. Every
log line carries the env tag automatically — enables `{env="dev"}` filters
in Loki without app changes.

---

## 4. Monitoring stack repo (`~/code/whitefield/monitoring/`)

Reused the skeleton of the pre-existing GlobalCodio grafana repo, renamed
every product reference, deleted its dashboards + alert rules, and rewrote
the scrape config for our needs.

### 4.1 Compose (`docker-compose.yml`)

Project name: `medicodio-monitoring`.

Services:

| Service | Image | Purpose |
|---|---|---|
| `prometheus` | `prom/prometheus:v2.55.1` | Scrape + TSDB |
| `loki` | `grafana/loki:main-550f590` | Log store |
| `grafana` | `grafana/grafana:12.0.2` | Dashboards + alerting (alerting off in Phase 1) |
| `node-exporter` | `prom/node-exporter:v1.8.2` | Host metrics — behind `profiles: [vm]` |

Details:

- `extra_hosts: host.docker.internal:host-gateway` on the prometheus
  service so it can reach the app containers running on the VM host from
  inside the docker bridge.
- Docker secrets used for scrape tokens — file lives at
  `/run/secrets/<name>` inside the prom container, referenced via
  `credentials_file:` in `prometheus.yml`. Keeps tokens out of the parsed
  config that `/api/v1/status/config` returns.
- Named volumes (`prom-data`, `loki-data`, `grafana-data`) survive
  `docker compose down`. Only `-v` wipes them.
- All UI ports bound to `127.0.0.1` — never publicly exposed. Reverse proxy
  is a separate concern.
- **UAT + PROD scrape jobs commented out** in both compose secrets and
  prometheus.yml — will be uncommented when those envs are wired.
- `node-exporter` is behind `profiles: [vm]` because:
  1. macOS Docker Desktop rejects the `rslave` propagation flag we need.
  2. Even if it started on macOS, it'd read Docker Desktop's Linux VM
     `/proc`, not the Mac.
  Local runs `docker compose up -d` (skips node-exporter). VM runs
  `docker compose -f docker-compose.yml --profile vm up -d`.

### 4.2 Prometheus config (`prometheus/prometheus.yml`)

- `global.scrape_interval: 30s`, `external_labels: { cluster: medicodio }`.
- Per-env scrape jobs:
  - `app-local` (local override file only)
  - `app-dev` (active)
  - `app-uat` / `app-prod` (commented out)
- `node-shared` — one job scraping `node-exporter:9100` (compose DNS).
  Single target represents the whole shared VM.
- Per-env token from a docker secret via `credentials_file:`.
- Retention **7 days** (was 30d — cut to preserve disk headroom until real
  data volume is known).

### 4.3 Prometheus targets (`prometheus/targets/*.yml`)

- `app-dev.yml`  → `host.docker.internal:8000`, labels
  `{env=dev, service=app, component=backend}`.
- `app-local.yml` → `host.docker.internal:8000`, labels `env=local`. Mounted
  via `docker-compose.override.yml` only.
- `node-shared.yml` → `node-exporter:9100`, labels
  `{env=shared, service=node, component=vm}`.
- `app-uat.yml` / `app-prod.yml` — files exist with `REPLACE_ME`
  placeholders, but their compose mounts + prometheus job entries are
  commented, so Prometheus ignores them.

### 4.4 Loki config (`loki/loki-config.yml`)

- Single-binary mode, filesystem storage, TSDB index.
- `auth_enabled: false` — Loki itself is unauth; access control comes from
  network layer (127.0.0.1 bind + reverse proxy in front of push endpoint
  for PROD).
- Retention **7 days** (`168h`), compactor-managed with 10-minute
  compaction interval.
- Conservative ingestion caps: 8 MB/s, 10 k streams, 256 KB max line.
  Enough for our BE, not enough for a runaway logger to fill the disk.

### 4.5 Grafana provisioning

Everything as-code:

- `grafana/provisioning/datasources/datasources.yml` — Prometheus (uid
  `prometheus`) and Loki (uid `loki`). Loki datasource has a derived field
  on `correlationId` — click a log line → jump to correlated logs.
- `grafana/provisioning/dashboards/dashboards.yml` — file provider,
  folder `Medicodio`, reloads every 10 s from
  `/var/lib/grafana/dashboards`.
- `grafana/provisioning/alerting/rules.yml` — empty groups array (rules
  built in Phase 1d if we need them).
- `contact-points.yml.disabled` + `policies.yml.disabled` — renamed to
  `.disabled` because Grafana 12 rejects a contact point whose URL is empty.
  Rename back when Teams webhooks are wired.

### 4.6 Dashboards (`grafana/dashboards/medicodio/`)

Three hand-authored JSONs, all filter by an `env` template variable:

- `app-health.json` — request rate, p95 latency, HTTP status breakdown,
  memory (RSS + heap), event-loop lag, job last success table, job runs
  table, error/warn log stream, live log stream.
- `vm-health.json` — CPU busy %, memory used %, disk used % per mount,
  load 1/5/15, network I/O, uptime. Sourced from node_exporter series.
- `logs-explorer.json` — log rate by level (Loki LogQL), full log stream
  with env + level filters.

`allowUiUpdates: true` on the dashboard provider — engineers can prototype
in the UI. `scripts/sync-all-dashboards.sh` pulls UI edits back to JSON for
committing.

### 4.7 Jenkins pipeline (`Jenkinsfile`)

Stages, in order:

1. **Azure Auth** — service-principal login.
2. **Preflight — VM resources** — reports disk, memory, CPU, Docker
   presence, `/mnt/grafana` size. Never fails; informational for humans.
3. **Ensure Docker installed** — idempotent. Skips if docker + compose
   plugin present. Runs `get.docker.com` if missing, adds
   `docker-compose-plugin`, enables the daemon, adds `MedicodioAdmin` to
   docker group. ~2 min first run, ~5 s afterwards.
4. **Checkout Code** — `docker compose -f docker-compose.yml --profile vm
   down --remove-orphans` (safe if nothing running), then
   `rm -rf /mnt/grafana`, then `git clone` fresh from
   `jatinkushwaha-medicodio/grafana:main`.
5. **Deploy** —
   ```
   cd /mnt/grafana
   cp /home/MedicodioAdmin/.nextgen-secrets/.env.grafana .env
   docker compose -f docker-compose.yml --profile vm up -d
   ```

All steps run via `az vm run-command invoke` — Jenkins never SSHes into
the VM.

### 4.8 Secrets on the VM

`/home/MedicodioAdmin/.nextgen-secrets/.env.grafana` (mode 0600, owned by
`MedicodioAdmin`). Populated by a one-shot `az vm run-command` at bootstrap:

```
GF_ADMIN_USER=admin
GF_ADMIN_PASSWORD=<strong>
DEV_METRICS_TOKEN=<hex32>
UAT_METRICS_TOKEN=<hex32>     # kept for future use, currently unused
PROD_METRICS_TOKEN=           # empty, secret + job commented
LOCAL_METRICS_TOKEN=          # empty, override file skipped on VM
LOKI_TOKEN=                   # empty until PROD reverse proxy lands
```

`DEV_METRICS_TOKEN` must match `METRICS_TOKEN` in the DEV BE container's
`.env`. UAT similarly when re-enabled.

---

## 5. Key design decisions (why, not just what)

1. **Single VM for everything.** Simplifies networking (`host.docker.internal`
   reaches app containers), one Jenkinsfile, one NSG. Trade-off: monitoring
   VM losing power = losing app too. Acceptable at current scale.

2. **Direct-push Winston transport for logs**, not Docker log driver
   plugin. Reason: PROD (ACA) cannot run a Docker log driver anyway; using
   the same code path everywhere means dev/uat mirror prod behaviour and the
   VM stays plugin-free.

3. **`env` label derived from `NODE_ENV`.** Avoids a redundant `APP_ENV`
   env var. `production` gets normalized to `prod` for cleaner Grafana
   filters.

4. **Timing-safe token compare.** `!==` leaks a timing side-channel on
   token length + prefix. `crypto.timingSafeEqual` closes it. Cheap.

5. **`route` label = `baseUrl + route.path`.** Two routers can share the
   same template (`/:id`), so `route.path` alone conflates unrelated
   endpoints. Composed label is unique per real endpoint.

6. **Serialize Loki flushes.** Size-triggered vs interval-triggered flushes
   can race and arrive out of order. Modern Loki accepts out-of-order
   writes, but a single-in-flight guard is a 5-line safety net.

7. **`node-exporter` behind `vm` profile.** macOS Docker Desktop rejects
   the `rslave` propagation, and even if it worked, metrics would report
   Docker Desktop's Linux VM — useless. Profile flag skips it locally,
   enables it on the real VM.

8. **7-day retention.** VM has 7.5 GB disk headroom after Docker install.
   30 d retention could grow into that. Cut to 7 d until we see real
   ingest rates. Trivial to bump back up.

9. **UI ports bound to `127.0.0.1`.** External access is deliberately a
   separate concern — expected to be nginx reverse proxy + TLS. Grafana
   over plain HTTP on a public port would leak admin creds.

10. **Alerting deferred.** `rules.yml` is empty; contact-points renamed
    `.disabled` because Grafana 12 rejects zero-URL Teams integrations.
    Rules + webhooks come once we know what to alert on.

11. **UAT + PROD commented out** rather than left with placeholder tokens.
    Reason: docker-compose secrets require the env var to *exist* (even
    empty); a missing var kills the whole compose up. Cleaner to comment.

12. **PostgreSQL exporter dropped from Phase 1.** Was in the plan; user
    decision to cut. `postgres_exporter` needs a DSN with a read-only
    role, and the DB is off-VM (Azure PG Flexible Server). Adds cost and
    ops without a demonstrated need. Can be added later without touching
    anything else.

---

## 6. What's not built (deliberate gaps)

- No external reachability. Grafana is `127.0.0.1:3030` only. Reverse
  proxy + NSG rule is the next chunk of work.
- No TLS. Same reason.
- No alert rules or notifications.
- No UAT wiring. Everything is scaffolded — files exist, jobs commented,
  tokens allocated but unused.
- No PROD wiring. Prometheus target file has `REPLACE_ME` in it. Loki push
  from ACA needs a public URL.
- No PostgreSQL observability.
- No product-usage / feature adoption analytics (Phase 2).
- No Alertmanager, Alloy, Tempo, OpenTelemetry collector.
- No backup cron for the three named volumes (documented in README as a
  recipe, not automated).
- Grafana MS OAuth scaffolded (env vars wired, provider config in
  `docker-compose.yml`) but disabled (`GF_OAUTH_ENABLED=false`).

---

## 7. Verification checklist (post-deploy)

Run these via `az vm run-command`:

```bash
# 1. Containers running
docker ps --format '{{.Names}}\t{{.Status}}'
# expect 4: prometheus, loki, grafana, node-exporter

# 2. Prometheus targets healthy
curl -s http://127.0.0.1:9090/api/v1/targets | jq \
  '.data.activeTargets[] | {job:.labels.job, instance:.labels.instance, health}'
# expect app-dev up, node-shared up

# 3. Loki accepting writes
curl -s http://127.0.0.1:3033/ready
# expect: ready

# 4. Grafana healthy
curl -s http://127.0.0.1:3030/api/health
# expect: {"database":"ok"}
```

BE-side (from anywhere with the token):

```bash
curl -s -H "Authorization: Bearer $DEV_METRICS_TOKEN" \
  https://api.dev.medicodio.ai/metrics | head
# expect prom text, labels {service="whitefield-app",env="dev"}
```

---

## 8. Repositories touched

| Repo | Changes |
|---|---|
| `medicodio-nextgen-app-nodejs` | `+prom-client`, `+winston-transport`, `src/lib/metrics.ts` (new), `src/lib/loki-transport.ts` (new), `src/lib/logger.ts` (extended), `src/config/env.ts` (+3 fields), `src/server.ts` (histogram middleware + `/metrics` + morgan skip), `src/jobs/index.ts` (+41 insertions, no deletions). |
| `jatinkushwaha-medicodio/grafana` (this repo) | Full rewrite: renamed from GlobalCodio; deleted old dashboards + alerts; new compose services (node-exporter); new prometheus jobs; three new dashboards; updated Jenkinsfile with preflight + docker-install stages. |

---

## 9. Contact / knowledge holders

- Monitoring pipeline: this doc + `README.md` + `docs/deploy-to-vm.md`.
- BE code changes: `src/lib/metrics.ts` and `src/lib/loki-transport.ts` are
  the only new files worth reading before extending observability.
- Ops asks:
  - Reverse proxy for external Grafana access (next task).
  - NSG opening whatever port the reverse proxy exposes.
  - Optional: DNS name for `grafana.medicodio.ai` (or similar).

---

## 10. Phase 2 — Product-Usage Analytics

Snapshot of what shipped alongside the observability stack. Full contract lives in
`medicodio-nextgen-app-nodejs/docs/analytics/README.md`; this section covers only
the monitoring-repo pieces.

### What the FE / BE side does

- **FE (`medicodio-nextgen-app-react/src/shared/analytics/`)** — mounts a
  `<PageViewTracker />` in `App.tsx`. Emits one event per route change plus
  ~15 hand-picked calls in state-driven tabs (Chart Queue buckets, Chart
  Details right-pane, Chart PDF ↔ Profile, Matrix ↔ Stacked, Payer Rules,
  prev/next encounter, History tabs, Mandatory Fields tabs, Access tabs).
  Batches every 30 s (also on visibilitychange/beforeunload) to
  `POST /api/v1/app/analytics/events`.
- **BE (`medicodio-nextgen-app-nodejs/src/routes/analytics.routes.ts` +
  `services/analytics/*`)** — validates the batch with Zod, drops events for
  users whose role slug is not in `analytics.tracked_roles`, sanitises
  `page_path` (UUIDs) + caps `props` at 4 KB, bulk-INSERTs under RLS.
  Kill switch: `ANALYTICS_ENABLED=false`.

### What the monitoring repo owns

- `grafana/provisioning/datasources/datasources.yml` — a third datasource
  `Postgres (App)` (uid `postgres_app`) reads from the app DB via a read-only
  `grafana_ro` role. Env vars come from `.env.grafana`:
  `APP_DB_HOST`, `APP_DB_PORT`, `APP_DB_NAME`, `APP_DB_ANALYTICS_USER`,
  `APP_DB_ANALYTICS_PASSWORD`.
- `docker-compose.yml` — passes the five `APP_DB_*` env vars through to the
  Grafana container. Blank values leave the datasource registered but panels
  show "No data".
- `grafana/dashboards/medicodio/product-usage.json` — the new dashboard.
  Six panels: most-visited areas, features, nested tabs, usage by role,
  usage by client, zero/low-usage features.

### Ops setup (one-time)

On the app Postgres:

```sql
CREATE ROLE grafana_ro WITH LOGIN PASSWORD '<generated>';
GRANT CONNECT ON DATABASE <app_db> TO grafana_ro;
GRANT USAGE ON SCHEMA public TO grafana_ro;
GRANT SELECT ON t_analytics_events, t_iam_users, t_iam_roles,
                t_org_clients, t_sys_features, t_sys_client_config
             TO grafana_ro;
ALTER ROLE grafana_ro BYPASSRLS;
```

Populate `.env.grafana` with the five `APP_DB_*` values on the monitoring VM.
Then rerun the monitoring pipeline — Grafana loads the new datasource + the
Product Usage dashboard on the next `docker compose up -d`.

### Retention / partitions

Not partitioned. Current traffic (~5 clients × ~20 users × ~50 events/user/day)
produces ~30 k rows / month at ~5 MB — comfortably below any partition need.
Triggers to revisit: row count > 10 M, insert p95 > 50 ms, or age-based DELETE
becomes a hot path.

### Rollback

- `ANALYTICS_ENABLED=false` on the BE stops writes system-wide within one
  request cycle. FE keeps enqueueing harmlessly.
- Per-client override `analytics.tracked_roles = []` in `t_sys_client_config`
  stops writes for that client only, within ~1 s (WS cache invalidate).
