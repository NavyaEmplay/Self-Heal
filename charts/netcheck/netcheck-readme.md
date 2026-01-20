I’ll produce two paste-ready READMEs (Maintainer + Tester) for your **netcheck** exactly in the same structure as your disk/memory ones, including full Helm chart code, email setup, logs-viewer usage, manual test job, and GitHub Pages publish steps in README-1.


## ✅ README-1 (Maintainer) — `netcheck` (with Email)

Save as: `charts/netcheck/netcheck-Readme.md`

````md
# netcheck Helm Chart (Self-Heal Network Connectivity Check + Email) — Maintainer Guide

This chart deploys a Kubernetes **CronJob** that checks **network connectivity** by calling a configured URL (default: Google).
If connectivity fails, it retries and then sends an **email alert** (with cooldown to avoid spam).

✅ Uses `curl` to test HTTP connectivity  
✅ Retries (`RETRY_COUNT`, `RETRY_INTERVAL`)  
✅ Cooldown (`COOLDOWN_PERIOD`) to avoid repeated alerts  
✅ Logs written to shared PVC `self-heal-logs-pvc`  
✅ State stored in PVC `netcheck-state` (cooldown timestamp)  
✅ Email via SMTP using curl (same style as disk/cpu)

---

## 0) What we are actually testing (Network check)

This job is validating: **Can this cluster run a simple outbound HTTP request to the target URL?**

Flow:
1. CronJob runs (default every 5 mins).
2. Runs: `curl -s --max-time <timeout> <target_url>`.
3. If success → logs Healthy.
4. If fail → retries N times with interval.
5. If still failing after retries → sends email (only if cooldown allows).
6. Writes logs to `/opt/logs/netcheck_YYYY-MM-DD.log`.

This is a **precheck/alert** (not auto-fix).

---

## 1) Prerequisites (Maintainer machine)

### 1.1 Install tools
```bash
sudo apt-get update -y
sudo apt-get install -y git curl ca-certificates
````

### 1.2 Install Helm

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

### 1.3 Install kubectl

```bash
curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client
```

---

## 2) One-time cluster setup (shared logs PVC + logs-viewer)

### 2.1 Apply shared logs PVC (ONE TIME per cluster)

```bash
cd ~/Emplay/self-heal-helm-repo
kubectl apply -f shared-logs-pvc.yaml
kubectl get pvc -n default | grep self-heal-logs-pvc
```

✅ Ensure `storageClassName: standard` (not `standar`).

### 2.2 Apply logs-viewer (ONE TIME per cluster)

```bash
kubectl apply -f logs-viewer.yaml
kubectl get pods -n default -l app=logs-viewer
```

---

## 3) Create chart folders

```bash
mkdir -p charts/netcheck/templates charts/netcheck/scripts
```

Expected:

```
charts/netcheck/
├─ Chart.yaml
├─ values.yaml
├─ templates/
│  └─ all.yaml
└─ scripts/
   ├─ checknetwork.sh
   └─ utils.sh
```

---

## 4) Add ALL chart files (copy/paste)

### 4.1 charts/netcheck/Chart.yaml

```yaml
apiVersion: v2
name: netcheck
description: Self-heal network connectivity CronJob (curl + retries + cooldown + email + logs)
type: application
version: 0.1.0
appVersion: "1.0.0"
```

---

### 4.2 charts/netcheck/values.yaml

```yaml
schedule: "*/5 * * * *"

image:
  repository: debian
  tag: bullseye-slim

config:
  RETRY_COUNT: "3"
  RETRY_INTERVAL: "10"
  COOLDOWN_PERIOD: "600"
  LOG_DIR: "/opt/logs"

  NETWORK_TARGET_URL: "https://www.google.com"
  CURL_TIMEOUT: "5"

  EMAIL_ENABLED: "true"
  EMAIL_SUBJECT_PREFIX: "[Self-Heal][Network]"
  EMAIL_FROM: "qa_emplay@emplay.net"
  EMAIL_TO: "nandhini.s@emplay.net,navya.sri@emplay.net"
  SMTP_HOST: "smtp.gmail.com"
  SMTP_PORT: "587"
  SMTP_USERNAME: "qa_emplay@emplay.net"

secrets:
  SMTP_PASSWORD: ""

persistence:
  state:
    size: 5Mi

sharedLogsPVC:
  name: "self-heal-logs-pvc"
```

---

### 4.3 charts/netcheck/scripts/utils.sh

```bash
#!/bin/bash

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" | tee -a "$LOG_DIR/netcheck_$(date '+%Y-%m-%d').log"
}

retry_with_config() {
  local cmd=$1 retries=$2 interval=$3 count=0
  until $cmd; do
    count=$((count+1))
    [ $count -ge $retries ] && return 1
    log "DEBUG" "Retry $count/$retries failed, sleeping $interval"
    sleep $interval
  done
  return 0
}

can_alert() {
  local cooldown=$1 file=/opt/state/last_alert now=$(date +%s)
  if [ -f $file ]; then
    last=$(<$file)
    if (( last + cooldown > now )); then
      remain=$(( last + cooldown - now ))
      log "INFO" "Cooldown active, skipping alert (wait ${remain}s more)"
      return 1
    fi
  fi
  echo $now > $file
  return 0
}

send_email() {
  local msg=$1

  SMTP_PASSWORD="$(cat "$SMTP_PASSWORD_FILE" 2>/dev/null || true)"

  if [ "$EMAIL_ENABLED" = "true" ]; then
    SUBJECT="$EMAIL_SUBJECT_PREFIX Connectivity Issue"
    BODY="ALERT: $msg"

    RCPT_ARGS=()
    for rcpt in $(echo "$EMAIL_TO" | tr ',' ' '); do
      RCPT_ARGS+=( --mail-rcpt "$rcpt" )
    done

    curl --silent --show-error --fail \
      --url "smtp://$SMTP_HOST:$SMTP_PORT" \
      --ssl-reqd \
      --mail-from "$EMAIL_FROM" \
      "${RCPT_ARGS[@]}" \
      --user "$SMTP_USERNAME:$SMTP_PASSWORD" \
      -T <(echo -e "From: $EMAIL_FROM\nTo: $EMAIL_TO\nSubject: $SUBJECT\n\n$BODY")
  fi
}
```

---

### 4.4 charts/netcheck/scripts/checknetwork.sh

```bash
#!/bin/bash
set -euo pipefail

source /opt/config/config.env
source /opt/utils/utils.sh

mkdir -p "$LOG_DIR" /opt/state
find "$LOG_DIR" -type f -name "netcheck_*.log" -mtime +7 -delete || true

check_network() {
  log "DEBUG" "Checking network connectivity to $NETWORK_TARGET_URL..."
  if curl -s --max-time "$CURL_TIMEOUT" "$NETWORK_TARGET_URL" > /dev/null; then
    log "INFO" "Network connectivity healthy (HTTP to $NETWORK_TARGET_URL succeeded)"
    return 0
  else
    log "WARNING" "Network connectivity issue detected (HTTP to $NETWORK_TARGET_URL failed)"
    return 1
  fi
}

if retry_with_config check_network "$RETRY_COUNT" "$RETRY_INTERVAL"; then
  exit 0
else
  if can_alert "$COOLDOWN_PERIOD"; then
    send_email "Connectivity to $NETWORK_TARGET_URL failed in namespace=${POD_NAMESPACE:-default} on host=$(hostname)"
    log "INFO" "Email sent (Target=$NETWORK_TARGET_URL)"
  fi
  exit 0
fi
```

---

### 4.5 charts/netcheck/templates/all.yaml

```yaml
{{- define "netcheck.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "netcheck.fullname" . }}-scripts
  namespace: {{ .Release.Namespace }}
data:
  config.env: |
    RETRY_COUNT={{ .Values.config.RETRY_COUNT }}
    RETRY_INTERVAL={{ .Values.config.RETRY_INTERVAL }}
    COOLDOWN_PERIOD={{ .Values.config.COOLDOWN_PERIOD }}
    LOG_DIR={{ .Values.config.LOG_DIR }}

    NETWORK_TARGET_URL={{ .Values.config.NETWORK_TARGET_URL }}
    CURL_TIMEOUT={{ .Values.config.CURL_TIMEOUT }}

    EMAIL_ENABLED={{ .Values.config.EMAIL_ENABLED }}
    EMAIL_SUBJECT_PREFIX="{{ .Values.config.EMAIL_SUBJECT_PREFIX }}"
    EMAIL_FROM={{ .Values.config.EMAIL_FROM }}
    EMAIL_TO={{ .Values.config.EMAIL_TO }}
    SMTP_HOST={{ .Values.config.SMTP_HOST }}
    SMTP_PORT={{ .Values.config.SMTP_PORT }}
    SMTP_USERNAME={{ .Values.config.SMTP_USERNAME }}
    SMTP_PASSWORD_FILE=/opt/secret/SMTP_PASSWORD

  utils.sh: |
{{ .Files.Get "scripts/utils.sh" | indent 4 }}

  checknetwork.sh: |
{{ .Files.Get "scripts/checknetwork.sh" | indent 4 }}

---
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "netcheck.fullname" . }}-smtp
  namespace: {{ .Release.Namespace }}
type: Opaque
stringData:
  SMTP_PASSWORD: {{ .Values.secrets.SMTP_PASSWORD | quote }}

---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "netcheck.fullname" . }}-state
  namespace: {{ .Release.Namespace }}
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: {{ .Values.persistence.state.size }}

---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: {{ include "netcheck.fullname" . }}-cron
  namespace: {{ .Release.Namespace }}
spec:
  schedule: {{ .Values.schedule | quote }}
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 120
      ttlSecondsAfterFinished: 300
      template:
        spec:
          securityContext:
            runAsUser: 0
            runAsGroup: 0
            fsGroup: 0
          restartPolicy: OnFailure
          containers:
          - name: netcheck
            image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
            command: ["/bin/bash","-c"]
            env:
              - name: POD_NAMESPACE
                valueFrom:
                  fieldRef:
                    fieldPath: metadata.namespace
            args:
              - |
                set -e
                apt-get update && \
                apt-get install -y curl ca-certificates && \
                bash /opt/scripts/checknetwork.sh
            volumeMounts:
            - name: scripts
              subPath: checknetwork.sh
              mountPath: /opt/scripts/checknetwork.sh
            - name: scripts
              subPath: config.env
              mountPath: /opt/config/config.env
            - name: scripts
              subPath: utils.sh
              mountPath: /opt/utils/utils.sh
            - name: state
              mountPath: /opt/state
            - name: logs
              mountPath: /opt/logs
            - name: smtpsecret
              mountPath: /opt/secret
              readOnly: true
          volumes:
          - name: scripts
            configMap:
              name: {{ include "netcheck.fullname" . }}-scripts
          - name: state
            persistentVolumeClaim:
              claimName: {{ include "netcheck.fullname" . }}-state
          - name: logs
            persistentVolumeClaim:
              claimName: {{ .Values.sharedLogsPVC.name }}
          - name: smtpsecret
            secret:
              secretName: {{ include "netcheck.fullname" . }}-smtp
```

---

## 5) Local test (Maintainer)

### 5.1 Lint + Install

```bash
cd ~/Emplay/self-heal-helm-repo/charts/netcheck
helm lint .

helm uninstall netcheck -n default 2>/dev/null || true
helm install netcheck . -n default --create-namespace \
  --set-string secrets.SMTP_PASSWORD="YOUR_SMTP_APP_PASSWORD"
```

Verify:

```bash
kubectl get cronjob -n default | grep netcheck
```

### 5.2 Manual test run (don’t wait for cron)

```bash
JOB="netcheck-manual-$(date +%Y%m%d-%H%M%S)"
kubectl create job --from=cronjob/netcheck-netcheck-cron "$JOB" -n default

POD=$(kubectl get pods -n default -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n default -f "$POD"
```

---

## 6) View logs in logs-viewer

```bash
kubectl exec -it -n default deploy/logs-viewer -- sh
ls -lh /opt/logs
tail -f /opt/logs/netcheck_$(date +%Y-%m-%d).log
```

---

## 7) Troubleshooting

### 7.1 Email error: `curl: (67) Login denied`

* Use Gmail **App Password**, not normal password
* `SMTP_USERNAME` must match the Gmail that generated the app password
* Ensure 2FA enabled on that Gmail account

### 7.2 Cluster has no outbound internet

If cluster runs in restricted network:

* set target URL to internal endpoint:
  `NETWORK_TARGET_URL=http://<internal-service>.<ns>.svc.cluster.local`

---

# ✅ Publish ALL charts to GitHub Pages (docs/) — Your exact safe steps

## Step 1: Go back to repo root

```bash
cd ~/Emplay/self-heal-helm-repo
ls
```

## Step 2: Clean build folder

```bash
rm -rf helm-repo/*
```

## Step 3: Package ALL charts (run from repo root only)

```bash
for d in charts/*; do
  [ -d "$d" ] && helm package "$d" -d helm-repo
done
```

Verify:

```bash
ls helm-repo
```

## Step 4: Create index.yaml

```bash
helm repo index helm-repo \
  --url https://NavyaEmplay.github.io/Self-Heal
```

Verify:

```bash
ls helm-repo
```

## Step 5: Publish to GitHub Pages (docs/)

```bash
rm -rf docs/*
cp -r helm-repo/* docs/
```

Verify:

```bash
ls docs
```

## Step 6: Commit & push

```bash
git add docs helm-repo charts/netcheck
git commit -m "Add netcheck chart + publish helm repo"
git push
```

Done ✅

````
