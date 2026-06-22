/*
 * Jenkinsfile — monitoring stack deploy pipeline.
 *
 * Triggered on push to `main`. Validates the config locally, then SSHs to the
 * monitoring VM and reconciles its checkout with the pushed commit:
 *   git pull → docker compose pull → docker compose up -d (NO -v)
 *
 * Volumes (`prom-data`, `loki-data`, `grafana-data`) are named and survive
 * `docker compose up -d` — 30d of TSDB / chunks / Grafana SQLite are preserved
 * across every deploy. NEVER add `-v` to the compose teardown unless you mean
 * to wipe all historical metrics + logs + Grafana state.
 *
 * Required Jenkins credentials:
 *   - monitoring-vm-ssh   (SSH private key with access to the VM as $VM_USER)
 *   - monitoring-vm-host  (string credential — public hostname / IP of the VM)
 *   - monitoring-vm-user  (string credential — usually `monitoring` or `ubuntu`)
 *   - monitoring-vm-path  (string credential — absolute path to the checkout on the VM, e.g. /opt/global-monitoring)
 */
pipeline {
  agent any

  options {
    timestamps()
    timeout(time: 15, unit: 'MINUTES')
    disableConcurrentBuilds()
    ansiColor('xterm')
  }

  triggers {
    githubPush()
  }

  environment {
    VM_HOST = credentials('monitoring-vm-host')
    VM_USER = credentials('monitoring-vm-user')
    VM_PATH = credentials('monitoring-vm-path')
  }

  stages {

    // ─── Local validation — fail fast on bad config before touching the VM ───
    stage('Validate config') {
      steps {
        sh '''
          set -e
          echo "--- compose syntax ---"
          docker compose -f docker-compose.yml config > /dev/null

          echo "--- prometheus.yml ---"
          docker run --rm -v "$PWD/prometheus":/work -w /work prom/prometheus:v2.55.1 \
            promtool check config prometheus.yml

          echo "--- loki-config.yml ---"
          docker run --rm -v "$PWD/loki":/work -w /work grafana/loki:3.2.1 \
            -config.file=/work/loki-config.yml -verify-config

          echo "--- dashboard JSON syntax ---"
          for f in grafana/dashboards/*.json; do
            jq empty "$f" || { echo "Invalid JSON: $f"; exit 1; }
          done

          echo "--- dashboard UIDs unique ---"
          dup=$(jq -r '.uid' grafana/dashboards/*.json | sort | uniq -d)
          if [ -n "$dup" ]; then echo "Duplicate dashboard UIDs: $dup"; exit 1; fi
        '''
      }
    }

    // ─── Deploy — SSH to the VM, git pull, docker compose reconcile ─────────
    stage('Deploy to monitoring VM') {
      when { branch 'main' }
      steps {
        sshagent(credentials: ['monitoring-vm-ssh']) {
          sh '''
            set -e
            ssh -o StrictHostKeyChecking=no "$VM_USER@$VM_HOST" bash -se <<EOF
              set -e
              cd "$VM_PATH"

              echo "--- git pull ---"
              git fetch --all
              git reset --hard "origin/main"

              echo "--- docker compose pull ---"
              docker compose pull

              echo "--- docker compose up -d (NO -v) ---"
              docker compose up -d --remove-orphans

              echo "--- verify health ---"
              # Give Prometheus + Loki ~10s to settle
              sleep 10
              curl -sf http://127.0.0.1:9090/-/ready
              curl -sf http://127.0.0.1:3100/ready
              curl -sf http://127.0.0.1:3030/api/health

              echo "--- volume status (sanity) ---"
              docker volume ls --filter name=globalcodio-monitoring_
EOF
          '''
        }
      }
    }

    // ─── Post-deploy smoke — confirm Prometheus reloaded the new config ─────
    stage('Smoke') {
      when { branch 'main' }
      steps {
        sshagent(credentials: ['monitoring-vm-ssh']) {
          sh '''
            ssh -o StrictHostKeyChecking=no "$VM_USER@$VM_HOST" \
              "curl -X POST -sf http://127.0.0.1:9090/-/reload && \
               curl -sf http://127.0.0.1:9090/api/v1/targets | \
                 jq '.data.activeTargets | map({job: .labels.job, health}) | group_by(.health) | map({health: .[0].health, count: length})'"
          '''
        }
      }
    }
  }

  post {
    success {
      echo "Monitoring stack reconciled to ${env.GIT_COMMIT}."
    }
    failure {
      // TODO: wire Slack / email when channel exists.
      echo "Deploy failed — VM left at previous state. No volumes touched."
    }
  }
}
