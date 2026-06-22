# GlobalCodio Monitoring Stack — Architecture Plan

## Context

We need observability for the NestJS API service (`apps/api`). Today: ad-hoc Application Insights + Sentry + a stub `/v1/health/metrics` (only `process_uptime_seconds`). Logs are structured JSON to stdout via `packages/utils/logger.ts` and `LoggingInterceptor`. No metrics aggregation, no historical retention we control, no team dashboards.

Goal: stand up a **minimal, open-source, independently-deployed** monitoring stack — Grafana + Prometheus + Loki only — that monitors Dev, UAT, Prod from a single VM. Keep app code changes small. Use existing structured-log shape. No Promtail / Alloy / Alertmanager / node_exporter for now.

Deployment reality confirmed with user:

- **Dev + UAT** → Docker on a shared VM (the monitoring stack lives on the same VM).
- **Prod** → Azure Container Apps.
- **Logs** → push to Loki directly from the app over HTTPS (no log shipper).
- **Metrics endpoint** → new top-level `/metrics` (not `/v1/health/metrics`).

Repo split: monitoring stack lives in `~/code/global/global-monitoring/` (separate repo). App-side changes (`/metrics` controller + Loki transport) live in the monorepo.

---

## Answers to design questions

### 3. One stack vs per-env stack

**One stack.** We are a startup. Three stacks = 3× volumes + 3× dashboards drift + 3× alert config + 3× ops. Single Prometheus with three jobs (`env=dev|uat|prod`); single Loki tenant; single Grafana. Failure-mode tradeoff: stack-down loses all three envs at once — acceptable today; revisit if Prod SLO commitments grow.

### 4. How Prometheus discovers Dev / UAT / Prod targets

Use `**file_sd_configs`**. One static file per env in `prometheus/targets/*.yml`, mounted as a volume. Targets + labels (`env`, `service`, `region`) live in those files. Prometheus auto-reloads when files change — no Prometheus restart on target adds.

Why not env-vars / hardcoded list in `prometheus.yml`:

- Env-vars in `prometheus.yml` need a templating step at compose-up (`envsubst`). Adds a wrapper. Fine for secrets, overkill for the target list.
- Hardcoded inline list bloats `prometheus.yml` and forces a reload on every change.
- `file_sd` keeps the config split: **secrets via env, target lists as data**.

Network topology:

- The 3 monitoring containers (Grafana, Prometheus, Loki) share **one internal docker network** owned by compose. Compose auto-creates a bridge network per project; service names resolve as DNS hostnames automatically (no `extra_hosts`, no manual DNS).
- can Scrape paths (uniform across all envs):

- Per-env target URL is **not hardcoded** — populated at deploy time. `targets/dev.yml` / `targets/uat.yml` / `targets/prod.yml` carry the URL + per-env labels. Final values supplied when the stack lands on the VM (we don't know domains / ports yet).
- Each scrape carries `Authorization: Bearer <METRICS_TOKEN>` (per-env token, read from compose `.env`).
- Each env's reverse proxy / ingress allowlists the monitoring VM's egress IP (defense in depth on top of the token).
- Schemes can be `https` (public ingress) or `http://<private-ip>:<port>` (if the env exposes `/metrics` only on a private VLAN reachable from the monitoring VM) — both fit the same `targets/*.yml` shape.

### 5. Networking & security

- `/metrics` is **never publicly accessible without a token**. The controller is `@Public()` (no JWT) but wrapped in `MetricsTokenGuard` which checks `X-Metrics-Token` or `Authorization: Bearer ...` against `METRICS_TOKEN` env. Per-env token; rotated via Key Vault on Prod.
- The 3 monitoring containers share one internal docker network (Grafana ↔ Prometheus ↔ Loki). External traffic is the only thing leaving that network.
- Every env scrape: HTTPS (or private-IP HTTP) + bearer token + IP allowlist at the env's ingress / reverse proxy.
- **Loki push** uses the same `Bearer <LOKI_TOKEN>` pattern. Each env's `LOKI_PUSH_URL` env-var points at the monitoring VM's Loki ingress — actual URL TBD when the VM gets a hostname / reverse-proxy. Token-gated, NOT public.
- **Grafana**: admin password from `.env`, anonymous disabled by default. For team access: Microsoft OAuth (reuses existing `MS_OAUTH`_* secrets) with `auto_assign_org_role = Viewer`. Editor role assigned by email allowlist in `grafana.ini`. UI ports `3000`/`9090`/`3100` NOT exposed on the VM's public interface — reach Grafana via Tailscale / Cloudflare Tunnel / SSH-tunnel. Prometheus/Loki HTTP ports only on docker network + localhost.
- VM firewall: only `22` and the tunnel port open. `9090`/`3100`/`3000` bound to `127.0.0.1` on the VM.

### 6. How logs flow into Loki (no shipper)

Add a **direct-push transport** in `packages/utils/logger.ts`. Existing `log()` already writes a structured `LogEntry` to stdout. Mirror that entry to a small batch queue; flush every 2s or 100 lines, whichever first. POST to `${LOKI_PUSH_URL}/loki/api/v1/push` with `Bearer <LOKI_TOKEN>`.

Properties:

- **Fail-open**: Loki down → log a single warn-once, keep writing stdout, drop excess buffer (cap 1000 entries).
- **Async + non-blocking**: never await in `log()`; flush runs on `setInterval`.
- **No PII risk added** — same entry that already goes to stdout; existing `.cursor/rules/observability.mdc` PII rules already enforce this.
- **Empty `LOKI_PUSH_URL` = transport no-op** (dev without monitoring stack).
- Levels: info + error today, ready for debug/warn without code changes.

Tradeoff acknowledged: app owns the network call on the hot path. Mitigated by async batching + cap. If Loki ever takes sustained downtime + buffer fills, log lines drop — preferable to back-pressuring requests. Revisit with Alloy + Docker logging driver in phase 2 if drop rate matters.

### 7. Label structure

**Prometheus** (stream labels — bounded cardinality only):

- Per-target via `file_sd`: `env=dev|uat|prod`, `service=api`, `region=eus|local`.
- Per-instance via `prometheus.yml` `external_labels`: `cluster=globalcodio` (added on `remote_write` later; harmless now).
- Histogram labels for `http_request_duration_seconds`: `method`, `route` (templated path, NOT raw), `status_class` (`2xx`/`3xx`/`4xx`/`5xx`).
- **Forbidden** label values (existing rule, repeat it): `requestId`, `userId`, `firmId`, free-text paths. Cardinality cap: per `.cursor/rules/observability.mdc` — 10k series per metric.

**Loki** (stream labels — same cardinality rule):

- `env`, `service`, `level` only. Everything else (`requestId`, `userId`, `path`, `module`) stays inside the JSON body and is filterable via LogQL `| json`.

This gives dashboards a clean `env=$env` template variable that filters both metrics + logs in one click.

### 8. Sharing dashboards (read-only)

- Microsoft OAuth via Grafana's generic OAuth provider (reuses `MS_OAUTH_`* secrets the app already loads). Default role `Viewer` (read-only).
- Editor allowlist: comma-separated emails in `GRAFANA_EDITOR_EMAILS`. Everyone else is Viewer.
- **All dashboards committed as JSON** in `grafana/dashboards/*.json`. Grafana provisioning re-applies them on every container restart — single source of truth is git, not the live UI. (UI edits live in the container's writable Grafana DB but are overridden on restart; that is the point.)

### 9. Surviving deploys + preserving history

- Monitoring stack repo (`global-monitoring`) is **independent of the app repo**. App deploys touch nothing here.
- Three **named Docker volumes** owned by compose: `prom-data`, `loki-data`, `grafana-data`. Volumes survive `docker compose down` (only removed by explicit `-v`).
- Prometheus retention: `--storage.tsdb.retention.time=30d` (tune later).
- Loki retention: `compactor.retention_enabled=true` + `retention_period=30d`.
- Grafana state lives in the `grafana-data` volume + provisioning files in git. Re-running the stack on a fresh VM = restore volume snapshots; everything else regenerates from git.
- Dashboards-as-code (JSON in git) means new team members get the same dashboards without touching the live Grafana.

---

## High-level architecture

```
                                ┌──────────────────────────┐
                                │   Monitoring VM          │
                                │   (separate from apps)   │
                                │                          │
                                │  docker-compose:         │
                                │  ┌────────────────────┐  │
   Dev   apps/api  ─────────────┼─►│ prometheus (scrape)│  │
   (HTTPS + Bearer + IP allow)  │  └─────────┬──────────┘  │
                                │            │             │
   UAT   apps/api  ─────────────┤            │             │
   (HTTPS + Bearer + IP allow)  │            ▼             │
                                │  ┌────────────────────┐  │
                                │  │ grafana            │◄─┼── MS OAuth (team)
                                │  └─────────▲──────────┘  │
                                │            │             │
   Prod  apps/api (ACA) ────────┤  ┌─────────┴──────────┐  │
   (HTTPS + Bearer + IP allow)  │  │ loki               │  │
                                │  └─────────▲──────────┘  │
                                │            │             │
                                └────────────┼─────────────┘
                                             │ HTTPS push
                                             │ (logger.ts batched)
                                             │
                              ┌──────────────┴────────────┐
                              │  apps/api (any env)       │
                              │  - GET  /metrics          │
                              │  - logger push to Loki    │
                              └───────────────────────────┘
```

---

## Folder structures

### Monitoring repo `~/code/global/global-monitoring/`

```
global-monitoring/
├── docker-compose.yml
├── .env.example                 # METRICS_TOKEN, LOKI_TOKEN, GF_*, retention knobs
├── .gitignore                   # .env
├── README.md                    # local + VM setup, OAuth wiring, rotation
├── ARCHITECTURE.md              # this document
├── prometheus/
│   ├── prometheus.yml           # scrape_configs use file_sd_configs
│   └── targets/
│       ├── dev.yml              # [{targets:["api-dev:3001"], labels:{env:dev,...}}]
│       ├── uat.yml
│       └── prod.yml             # https://api.prod... with auth token via env
├── loki/
│   └── loki-config.yml          # single-binary mode, filesystem chunks, 30d retention
└── grafana/
    ├── provisioning/
    │   ├── datasources/
    │   │   └── datasources.yml  # Prometheus + Loki, default uid=prom / loki
    │   └── dashboards/
    │       └── dashboards.yml   # provider pointing at /var/lib/grafana/dashboards
    └── dashboards/
        └── api-overview.json    # one starter dashboard; rate, p95, 5xx, log panel
```

### Monorepo additions (minimal)

- `apps/api/src/common/metrics/metrics.module.ts` *(new)*
- `apps/api/src/common/metrics/metrics.controller.ts` *(new — top-level `/metrics`, token-guarded)*
- `apps/api/src/common/metrics/metrics.service.ts` *(new — owns `prom-client` registry + Histogram)*
- `apps/api/src/common/metrics/metrics-token.guard.ts` *(new)*
- `apps/api/src/common/request-context/logging.interceptor.ts` *(edit — call `MetricsService.observeHttp(...)` in the same finalize block that already computes `duration` + `statusBucket`)*
- `apps/api/src/app.module.ts` *(edit — register `MetricsModule`)*
- `apps/api/src/health/health.controller.ts` *(edit — delete the stub `/v1/health/metrics` body and method)*
- `packages/utils/src/logger.ts` *(edit — add Loki push transport behind `LOKI_PUSH_URL`)*
- `apps/api/.env.example` *(edit — add `METRICS_TOKEN`, `LOKI_PUSH_URL`, `LOKI_TOKEN`, `APP_ENV`)*
- `apps/api/package.json` *(edit — add `prom-client@^15`)*

No frontend changes, no DB changes, no shared-types changes. No migration. No new package.

---

## Critical files to read before implementation

- `apps/api/src/common/request-context/logging.interceptor.ts` — already computes `duration` + `statusBucket`; reuse the finalize block; do not write a second middleware.
- `packages/utils/src/logger.ts` — already produces the canonical `LogEntry`. The Loki transport piggy-backs on the same entry; do not create a parallel logger.
- `apps/api/src/app.module.ts` — module registration site.
- `apps/api/src/main.ts` — confirms `@Public()` works for the new controller and that `app.enableShutdownHooks()` already covers graceful stop (let the metrics interval die with the process).
- `.cursor/rules/observability.mdc` — naming + label + PII rules. The new metric name follows `<service>_<subject>_<unit>` (`api_http_request_duration_seconds`).
- `apps/api/src/health/runtime-diagnostics.service.ts` — kept as-is; eventloop + pg-pool gauges can be pulled into `prom-client` later, not in this phase.

---

## Reuse vs new


| Need                                  | Reuse                                                          | New                                                                          |
| ------------------------------------- | -------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Per-request duration + status bucket  | `LoggingInterceptor` (already computes both)                   | —                                                                            |
| Structured log shape                  | `packages/utils/src/logger.ts` `LogEntry`                      | —                                                                            |
| Service name on logs                  | `setServiceName('api')` (already wired in `main.ts`)           | —                                                                            |
| RequestID context                     | `RequestContextStore` + `setRequestIdProvider` (already wired) | —                                                                            |
| `@Public()` decorator                 | `apps/api/src/modules/auth/guards/public.decorator.ts`         | —                                                                            |
| HTTP histogram + default Node metrics | —                                                              | `MetricsService` (thin wrapper over `prom-client`)                           |
| Metrics auth                          | —                                                              | `MetricsTokenGuard` (header check, no JWT)                                   |
| Loki push                             | —                                                              | `LokiTransport` inside `packages/utils/src/logger.ts` (~60 lines, fail-open) |


---

## Implementation phases (do in this order; each phase is independently verifiable)

1. **App: `/metrics` endpoint.** Add `prom-client`. Wire `MetricsModule` → controller + guard + service. `collectDefaultMetrics({ register })`. One Histogram `api_http_request_duration_seconds{method,route,status_class}`. Edit `LoggingInterceptor` to call `metricsService.observeHttp(...)` in the existing `finalize` block. Delete stub. Verify `curl -H "X-Metrics-Token: $T" localhost:3001/metrics` returns Prometheus text with `process_`*, `nodejs_`*, `api_http_request_duration_seconds_*` series.
2. **App: Loki transport.** Edit `packages/utils/src/logger.ts`. Add `LokiTransport` class: buffer + setInterval flush + fail-open fetch. Read `LOKI_PUSH_URL`, `LOKI_TOKEN`, `APP_ENV`, `_serviceName` at init. Empty URL = no-op. Unit-test the batching + drop-on-overflow path.
3. **Monitoring repo: stack up.** Scaffold `~/code/global/global-monitoring`. `docker-compose.yml` with three services + named volumes + isolated network + `127.0.0.1:`-bound ports. `prometheus.yml` with `file_sd_configs` pointing at `targets/*.yml`. `loki-config.yml` single-binary, filesystem. `grafana/provisioning/`* wiring datasources + dashboards. One starter dashboard JSON. README with local + VM bring-up.
4. **Wire Dev/UAT scrape.** For each env, once the address is known: (a) env's ingress / reverse proxy IP-allowlists the monitoring VM's egress IP, (b) URL goes into `targets/dev.yml` + `targets/uat.yml` along with `env`/`service`/`region` labels; per-env token lives in compose `.env` and is pulled into the `authorization` block. Reload (`curl -X POST localhost:9090/-/reload`). Confirm targets show "up" in `/targets`. Uniform treatment with Prod — Dev/UAT do not share a docker network with monitoring.
5. **Wire Prod scrape.** Same recipe — ACA ingress IP-allowlist + `targets/prod.yml` with the ACA URL + `authorization` block pulling the prod-env token. Confirm "up".
6. **Wire Loki push (Dev/UAT first).** Expose Loki on the monitoring VM behind a reverse proxy with HTTPS + token gate (URL TBD when VM lands). Set `LOKI_PUSH_URL` + `LOKI_TOKEN` on api-dev + api-uat. Confirm `{env="dev",service="api"} |= "HTTP"` in Grafana Explore returns lines. Then Prod with the same URL.
7. **Grafana team access.** Configure Microsoft OAuth via `grafana.ini` (or env-var equivalents). Default Viewer role. Editor allowlist. Verify a teammate signs in and sees the dashboards read-only.

---

## Out of scope (file as future work, do not build now)

- Alertmanager + alert rules (need SLO sign-off first).
- **node_exporter / cAdvisor** (host + container metrics) — see explicit tradeoff below.
- Promtail / Alloy log shipper (replace app-side push once log volume grows).
- Tracing (Tempo / Jaeger).
- Long-term storage (Thanos, Mimir, Grafana Cloud remote_write).
- Per-firm dashboards / tenant SLOs.
- Migration off Application Insights (run dual-pane until parity reached).

### Tradeoff: no node_exporter / cAdvisor

Fine for first iterations — keeps the stack at 3 containers. What we lose visibility on:

- **CPU usage** (host + per-container)
- **Memory pressure** (host + per-container, OOM-kill events)
- **Disk space** (the monitoring VM's own volumes, the app VMs' volumes)
- **Container restarts** (crashes that the API can't self-report)
- **Network I/O** (saturation, dropped packets)

We *do* get from `prom-client`'s default Node metrics: `api_process_cpu_seconds_total`,
`api_process_resident_memory_bytes`, `api_nodejs_heap_size_used_bytes`, GC pauses,
event-loop lag. Enough to spot most app-side problems. Blind to anything that kills
the process before it can scrape or to host-level resource exhaustion.

When to add them (phase 2 trigger): the first time we ask "is this slow because of
CPU or because of the DB?" and can't tell from app metrics alone. node_exporter +
cAdvisor are then a 2-container add to this same stack, scraped by the same
Prometheus, dashboarded under the existing Grafana — no architectural change.

---

## Verification (end-to-end test plan)

After implementation, run from the monitoring VM:

```bash
# Phase 1 verification — metrics endpoint (run against any env's API URL)
curl -s -H "X-Metrics-Token: $METRICS_TOKEN" "$API_URL/metrics" | grep api_http_request_duration_seconds_bucket
# Expect: histogram buckets for at least one labelled series

# Phase 3 — stack up
docker compose -f ~/code/global/global-monitoring/docker-compose.yml up -d
curl -s localhost:9090/-/ready                # Prometheus ready
curl -s localhost:3100/ready                  # Loki ready
curl -s -u admin:$GF_ADMIN_PASSWORD localhost:3000/api/health  # Grafana ok

# Phase 4 — targets up
curl -s localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {labels:.labels,health}'
# Expect all three env targets health="up"

# Phase 6 — logs in Loki
curl -s -G localhost:3100/loki/api/v1/query_range \
  --data-urlencode 'query={env="dev",service="api"}' \
  --data-urlencode 'start='"$(date -u -d '5 min ago' +%s)000000000"
# Expect at least one stream
```

Dashboard smoke test: open Grafana → API Overview → switch `$env` between dev/uat/prod → rate, p95, 5xx, log panel all render with data per env.

---

## Risks / things to flag

- **Loki push from app on hot path.** Acceptable now (async + capped buffer). Will need Alloy if Prod log volume exceeds ~500 lines/s — measure at week 2.
- **Single-instance Prometheus + Loki = single point of failure.** Acceptable for startup. Daily volume snapshot to Azure Blob is cheap insurance; add it in phase 2.
- **Prod scrape over public ingress** even with token + IP allowlist is more attack surface than VNet-peered private ingress. Note for later: ACA private ingress + VNet integration is the production-grade upgrade.
- **Monitoring repo split** means two PRs to ship a new dashboard (one to monitoring repo, one to provisioning). Acceptable for the "monitoring deployed independently" requirement.
- The user's original brief described UAT as VM-hosted, while `tech_architecture.md` says ACA. We are following the user's answer (UAT on VM); `tech_architecture.md` should be corrected in a follow-up doc PR.

