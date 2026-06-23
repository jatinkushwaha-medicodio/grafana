# Deploy to VM — Production Runbook

End-to-end deploy of the monitoring stack onto a VM that already hosts the
DEV + UAT app containers. Prod runs on Azure Container Apps and is reached
over its public HTTPS ingress.

Single command on the VM: `docker compose -f docker-compose.yml up -d`
(the `-f` flag skips `docker-compose.override.yml`, which is dev-only).

---

## 0. Pre-flight checklist

Before touching the VM, gather:

- [ ] **VM**: Ubuntu 22.04+ (or any Linux with Docker 24+), 2 vCPU / 4GB RAM minimum, 50GB disk for 30d retention.
- [ ] **DNS**: A record `grafana.<domain>` → VM public IP. Optional: `loki.<domain>` → same VM (only needed if pushing Loki logs from outside the VM, e.g. Prod ACA).
- [ ] **Azure App registration** access (to add prod redirect URI + rotate client secret).
- [ ] **Monitoring VM's egress public IP** (`curl ifconfig.me` from the VM). Each env's API ingress must allowlist this.
- [ ] **Each env's API admin** access (you'll need to set `METRICS_TOKEN`, `LOKI_PUSH_URL`, `LOKI_TOKEN` env-vars on Dev / UAT / Prod API containers).
- [ ] **Microsoft Teams** access to create 2 more workflow webhooks (uat-alerts, prod-alerts channels).

---

## 1. Provision VM + install Docker

```bash
ssh ops@<vm-ip>

# Docker + compose (Ubuntu)
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
exit && ssh ops@<vm-ip>     # re-login to pick up group

# Verify
docker --version
docker compose version
```

Open firewall ports:

```bash
sudo ufw allow 22/tcp     # SSH
sudo ufw allow 80/tcp     # HTTP (Caddy redirects → 443)
sudo ufw allow 443/tcp    # HTTPS (Caddy, Grafana via reverse proxy)
sudo ufw enable
# Do NOT open 3000/9090/3100 — those bind 127.0.0.1 only.
```

---

## 2. Clone repo + secrets

```bash
sudo mkdir -p /opt && sudo chown $USER /opt
cd /opt
git clone <repo-url> global-monitoring
cd global-monitoring

cp .env.example .env
```

Generate fresh secrets (do NOT reuse local-dev values):

```bash
echo "GF_ADMIN_PASSWORD=$(openssl rand -hex 32)"
echo "DEV_METRICS_TOKEN=$(openssl rand -hex 32)"
echo "UAT_METRICS_TOKEN=$(openssl rand -hex 32)"
echo "PROD_METRICS_TOKEN=$(openssl rand -hex 32)"
echo "LOKI_TOKEN=$(openssl rand -hex 32)"
```

Paste each value into `.env`, replacing the placeholders. Also set:

```
GF_SERVER_ROOT_URL=https://grafana.<domain>/

# Rotate the Azure OAuth client secret — create a NEW one in Azure App
# registration (Certificates & secrets → New client secret), expire the
# local-dev one. Paste the new value here:
GF_OAUTH_CLIENT_SECRET=<new-secret>
```

Don't touch:
- `GF_OAUTH_CLIENT_ID` (same Azure app)
- `GF_OAUTH_AUTH_URL` / `TOKEN_URL` / `API_URL` (same tenant)
- `TEAMS_WEBHOOK_URL_DEV` (reuse — that's the working channel)

Replace UAT + PROD Teams webhooks once you create those channels (see step 6).

---

## 3. Update Prometheus target URLs

Three files, one URL per env. Use the actual reachable hostnames:

```yaml
# prometheus/targets/dev.yml
- targets: ["api-dev.<domain>"]
  labels: { env: dev, service: api, region: <region> }

# prometheus/targets/uat.yml
- targets: ["api-uat.<domain>"]
  labels: { env: uat, service: api, region: <region> }

# prometheus/targets/prod.yml
- targets: ["api.<domain>"]
  labels: { env: prod, service: api, region: eus }
```

The `local.yml` file is dev-only (override-mounted). On VM it's irrelevant.

---

## 4. Caddy reverse proxy for HTTPS

Install Caddy:

```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install -y caddy
```

Write `/etc/caddy/Caddyfile`:

```caddy
grafana.<domain> {
  reverse_proxy localhost:3030
}

# Only needed if Prod ACA (or any external API) pushes logs to Loki.
# Skip this block if all log pushers are on this same VM.
loki.<domain> {
  @authorized header Authorization "Bearer {env.LOKI_TOKEN}"
  handle @authorized {
    reverse_proxy localhost:3100
  }
  handle {
    respond "Unauthorized" 401
  }
}
```

Load `LOKI_TOKEN` for Caddy:

```bash
sudo systemctl edit caddy   # opens override file
```

Add:
```ini
[Service]
Environment="LOKI_TOKEN=<paste-the-LOKI_TOKEN-value-from-.env>"
```

Save + reload:

```bash
sudo systemctl reload caddy
sudo systemctl enable caddy
```

Caddy auto-provisions Let's Encrypt certs on first hit. Confirm DNS resolves
before reloading or cert issuance fails.

---

## 5. Update Azure App registration

Azure portal → App registrations → **Grafana** → **Authentication** →
**Add Redirect URI**:

```
https://grafana.<domain>/login/generic_oauth
```

Keep the existing localhost / devtunnel URI for local dev unless you want to
remove it.

---

## 6. Create UAT + Prod Teams channels

For each (UAT, Prod):

1. Teams → your monitoring Team → **Add channel** → `alerts-uat` (or `alerts-prod`).
2. Open channel → **...** → **Workflows** → search **Send webhook alerts to a channel** → name `Grafana UAT Alerts` / `Grafana Prod Alerts` → Save.
3. Copy the URL.

Paste both into `.env`:

```
TEAMS_WEBHOOK_URL_UAT="<uat-url>"
TEAMS_WEBHOOK_URL_PROD="<prod-url>"
```

(Quote the values — they contain `&`.)

---

## 7. First boot

```bash
cd /opt/global-monitoring
docker compose -f docker-compose.yml up -d
```

⚠️ Note the `-f docker-compose.yml` flag — it skips `docker-compose.override.yml`
which contains local-only wiring (`host.docker.internal`, `local_metrics_token`).
**Always include this flag on the VM.**

Health checks:

```bash
docker compose -f docker-compose.yml ps
curl -sf http://127.0.0.1:9090/-/ready
curl -sf http://127.0.0.1:3100/ready
curl -sf -u admin:<GF_ADMIN_PASSWORD> http://127.0.0.1:3030/api/health
curl -sf https://grafana.<domain>/api/health    # via Caddy + TLS
```

Open `https://grafana.<domain>/` → "Sign in with Microsoft" → land as Viewer.

---

## 8. Wire each env's API

For each env (Dev, UAT, Prod), set these env-vars on the API container:

| Env-var | Value |
|---|---|
| `METRICS_TOKEN` | Same value as `<ENV>_METRICS_TOKEN` from monitoring VM `.env` |
| `APP_ENV` | `dev` / `uat` / `prod` |
| `LOKI_PUSH_URL` | `https://loki.<domain>` (if VM-external push) OR `http://<vm-private-ip>:3100` (if VM-internal) |
| `LOKI_TOKEN` | Same value as monitoring VM `.env` `LOKI_TOKEN` |

For Dev + UAT (same VM): `LOKI_PUSH_URL=http://monitoring-loki:3100` works if their containers share the monitoring network. Otherwise use VM private IP.

For Prod ACA: `LOKI_PUSH_URL=https://loki.<domain>`. The ACA-side network must reach this VM publicly (it can — ACA has internet egress).

Then **IP-allowlist the monitoring VM's public IP** at each env's API ingress:
- Dev/UAT (likely Caddy on the same VM): no allowlist needed; Prometheus scrapes via internal DNS or VM private IP.
- Prod (ACA): Portal → Container App → Networking → **Ingress restrictions** → Add Allow rule for monitoring VM's egress IP.

---

## 9. Verify end-to-end

```bash
# 1. All 3 targets UP
curl -s http://127.0.0.1:9090/api/v1/targets \
  | jq '.data.activeTargets[] | {job:.labels.job, env:.labels.env, health, lastError}'

# 2. Logs flowing for all envs
curl -s -G http://127.0.0.1:3100/loki/api/v1/label/env/values | jq

# 3. Alert rules live
curl -s -u admin:<pwd> http://127.0.0.1:3030/api/v1/provisioning/alert-rules \
  | jq '.[] | {title, folderUID}'

# 4. Trigger a real Teams alert (Dev channel)
# Hit a 5xx endpoint repeatedly on Dev API for 2 minutes, then check the
# alerts-dev Teams channel.
```

---

## 10. Ongoing operations

### Updating dashboards / configs

This is GitOps. Push to `main`, Jenkins SSHes to VM, runs:

```bash
cd /opt/global-monitoring
git pull
docker compose -f docker-compose.yml pull          # if image tags changed
docker compose -f docker-compose.yml up -d         # NO -v — volumes preserved
```

The provisioner picks up dashboard / datasource / alert JSON within 10s
without container restart.

### Rotating a secret

1. Generate new value: `openssl rand -hex 32`
2. Update `.env` on VM (single source of truth)
3. Update the corresponding API container's matching env-var (Azure / Kubernetes config)
4. `docker compose -f docker-compose.yml up -d --force-recreate grafana prometheus`

### Backup / disaster recovery

Volumes (`prom-data`, `loki-data`, `grafana-data`) hold all stateful data.
**Tier-1 stuff (dashboards, alert rules, datasources) is in git** — gets
re-applied on a fresh container automatically. Optional nightly snapshot:

```bash
# /etc/cron.daily/monitoring-backup.sh
#!/bin/bash
set -e
SNAP_DIR=/var/backups/monitoring
mkdir -p $SNAP_DIR
for v in prom-data loki-data grafana-data; do
  docker run --rm -v globalcodio-monitoring_$v:/src:ro -v $SNAP_DIR:/dst alpine \
    tar czf /dst/$v-$(date +%F).tgz -C /src .
done
# Optional: aws s3 / az storage upload to off-VM storage, rotate 7d
find $SNAP_DIR -name "*.tgz" -mtime +7 -delete
```

To restore: `docker compose down` → `tar xzf` into the volume mount path → `docker compose up -d`.

### Adding a 4th service (worker / scheduler / agent)

1. Wire `prom-client` + `/metrics` endpoint in the new service (same pattern as API).
2. Add scrape job in `prometheus/prometheus.yml` for each env.
3. Add new target files under `prometheus/targets/` (or extend existing).
4. Update API Overview dashboard's `$service` variable — auto-discovers new values from label scan.
5. Commit + push → Jenkins deploys.

---

## 11. Common failure modes

| Symptom | Diagnosis | Fix |
|---|---|---|
| Grafana 502 on `grafana.<domain>` | Caddy can't reach localhost:3030 | `docker compose ps grafana` — was it actually up? Re-check 127.0.0.1 binding. |
| OAuth `AADSTS50011 redirect URI mismatch` | Azure doesn't have the prod URI | Add `https://grafana.<domain>/login/generic_oauth` in Azure App reg → Authentication |
| OAuth callback lands on `localhost:3030/...` | `GF_SERVER_ROOT_URL` wrong | Re-check `.env`, recreate grafana container |
| All prom targets DOWN | Wrong tokens or no IP allowlist | Compare `.env` `<ENV>_METRICS_TOKEN` against each API's `METRICS_TOKEN`. Then check API ingress IP-allowlist includes VM egress IP. |
| Loki streams empty for one env | API's `LOKI_PUSH_URL` unreachable | From that env container: `curl -v https://loki.<domain>/ready` |
| Loki push returns 401 | Token mismatch | API's `LOKI_TOKEN` != Caddy's `LOKI_TOKEN` env var |
| Teams alert fires but no message in channel | Webhook URL stale / expired | Re-create the Workflow in Teams (URLs don't expire but Workflow can be disabled). Update `.env`, restart Grafana. |
| Dashboards / alert rules disappear | Provisioner unloaded a file (deleted on disk) + `disableDeletion: false` | Restore from git: `git pull && docker compose -f docker-compose.yml up -d --force-recreate grafana` |

---

## 12. Quick reference — what differs local vs VM

| Aspect | Local dev | VM |
|---|---|---|
| Bring-up command | `docker compose up -d` | `docker compose -f docker-compose.yml up -d` |
| Override file | Auto-loaded | Explicitly bypassed |
| `api-local` scrape job | UP, scrapes host's Node API | 0 targets, silent |
| `local_metrics_token` secret | Mounted from `LOCAL_METRICS_TOKEN` env | Not present |
| Public ingress | None (port 3030 on 127.0.0.1 only) | Caddy → 443 + TLS |
| Grafana root URL | `http://localhost:3030` or devtunnel | `https://grafana.<domain>` |
| OAuth callback URL | `http://localhost:3030/...` or devtunnel | `https://grafana.<domain>/...` |
| `.env` source | Git-ignored, dev passwords | Git-ignored, freshly-rotated prod secrets |
| Teams webhooks | DEV channel only | All 3 channels |
