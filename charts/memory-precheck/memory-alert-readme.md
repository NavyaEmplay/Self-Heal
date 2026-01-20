## ✅ README-1 (Maintainer) — `memory-precheck` (with Email)

Save as: `charts/memory-precheck/memory-precheck-Readme.md`

````md
# memory-precheck Helm Chart (Self-Heal Memory Precheck + Email) — Maintainer Guide

This chart deploys a Kubernetes **CronJob** that performs a **Memory precheck** across all nodes using `kubectl top nodes`.
If memory crosses threshold, it retries and then sends an **email alert** (with cooldown to prevent spam).

✅ Uses `kubectl top nodes` (metrics-server required)  
✅ Compares against `MEMORY_THRESHOLD`  
✅ Retries (`RETRY_COUNT`, `RETRY_INTERVAL`)  
✅ Cooldown (`COOLDOWN_PERIOD`) to avoid repeated alerts  
✅ Logs written to shared PVC `self-heal-logs-pvc`  
✅ State stored in PVC `memory-precheck-state`  
✅ Email via SMTP using curl (same style as disk/cpu)

---

## 0) What we are actually testing (Memory precheck)

This job is validating: **Is any node memory usage high right now?**

Flow:
1. CronJob runs on schedule.
2. Reads node MEMORY% using `kubectl top nodes`.
3. If any node MEMORY% >= threshold → alert condition.
4. Retries N times.
5. If still high after retries → sends email (only if cooldown allows).
6. Writes logs to `/opt/logs/memoryprecheck_YYYY-MM-DD.log`.

This is an **alert/precheck** (not self-heal fix).

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

## 3) Metrics-server must be working (REQUIRED)

Chart depends on:

```bash
kubectl top nodes
```

Verify:

```bash
kubectl top nodes
```

Minikube fix:

```bash
minikube addons enable metrics-server
kubectl -n kube-system get pods | grep metrics
```

Wait 1–2 mins then retry:

```bash
kubectl top nodes
```

---

## 4) Create chart folders

```bash
mkdir -p charts/memory-precheck/templates charts/memory-precheck/scripts
```

Expected:

```
charts/memory-precheck/
├─ Chart.yaml
├─ values.yaml
├─ templates/
│  └─ all.yaml
└─ scripts/
   ├─ checkmemory_precheck.sh
   └─ utils.sh
```

---

## 5) Add ALL chart files (copy/paste)

### 5.1 charts/memory-precheck/Chart.yaml

```yaml
apiVersion: v2
name: memory-precheck
description: Self-heal Memory precheck CronJob (kubectl top nodes + retries + cooldown + email + logs)
type: application
version: 0.1.0
appVersion: "1.0.0"
```

---

### 5.2 charts/memory-precheck/values.yaml

```yaml
schedule: "*/10 * * * *"

image:
  repository: python
  tag: 3.11-slim

config:
  RETRY_COUNT: "10"
  RETRY_INTERVAL: "5"
  COOLDOWN_PERIOD: "600"
  MEMORY_THRESHOLD: "60"
  LOG_DIR: "/opt/logs"

  EMAIL_ENABLED: "true"
  EMAIL_SUBJECT_PREFIX: "[Self-Heal][Memory-Precheck]"
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

### 5.3 charts/memory-precheck/scripts/utils.sh

```bash
#!/bin/bash

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" | tee -a "$LOG_DIR/memoryprecheck_$(date '+%Y-%m-%d').log"
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
  local cooldown=$1 file=/opt/state/last_memory_precheck_alert now=$(date +%s)
  if [ -f $file ]; then
    last=$(<$file)
    if (( last + cooldown > now )); then
      remain=$(( last + cooldown - now ))
      log "INFO" "Cooldown active, skipping memory precheck alert (wait ${remain}s more)"
      return 1
    fi
  fi
  echo $now > $file
  return 0
}

send_email() {
  local node=$1
  local usage=$2

  SMTP_PASSWORD="$(cat "$SMTP_PASSWORD_FILE" 2>/dev/null || true)"

  if [ "$EMAIL_ENABLED" = "true" ]; then
    SUBJECT="$EMAIL_SUBJECT_PREFIX High Memory Precheck Alert on $node"
    BODY="ALERT: Node=$node Memory=${usage}% (Threshold=${MEMORY_THRESHOLD}%)"

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

### 5.4 charts/memory-precheck/scripts/checkmemory_precheck.sh

```bash
#!/bin/bash
set -euo pipefail

source /opt/config/config.env
source /opt/utils/utils.sh

mkdir -p "$LOG_DIR" /opt/state
find "$LOG_DIR" -type f -name "memoryprecheck_*.log" -mtime +7 -delete || true

check_memory() {
  log "DEBUG" "Checking Memory usage across all nodes (precheck)..."
  alert=0
  max_usage=0
  max_node=""
  total_count=0

  # kubectl top nodes columns:
  # NAME CPU(cores) CPU% MEMORY(bytes) MEMORY%
  while read -r node cpu_cores cpu_pct mem_bytes mem_pct; do
    usage="${mem_pct%\%}"
    total_count=$((total_count+1))

    if [ "$usage" -ge "$MEMORY_THRESHOLD" ]; then
      log "WARNING" "Node $node is above memory threshold (precheck): ${usage}%"
      alert=1
    else
      log "INFO" "Node $node memory healthy (precheck): ${usage}%"
    fi

    if [ "$usage" -gt "$max_usage" ]; then
      max_usage=$usage
      max_node=$node
    fi
  done < <(kubectl top nodes --no-headers | awk '{print $1, $2, $3, $4, $5}')

  echo "$max_node" > /opt/state/max_memory_precheck_node
  echo "$max_usage" > /opt/state/max_memory_precheck_usage

  if [ $alert -eq 0 ]; then
    log "INFO" "All $total_count nodes memory healthy (precheck). Highest usage=$max_usage% on $max_node"
  else
    log "ERROR" "High Memory detected (precheck). Worst=$max_usage% on $max_node"
  fi

  return $alert
}

on_persisting_high_memory() {
  if can_alert "$COOLDOWN_PERIOD"; then
    NODE=$(cat /opt/state/max_memory_precheck_node 2>/dev/null || echo "")
    USAGE=$(cat /opt/state/max_memory_precheck_usage 2>/dev/null || echo "0")
    if [ -n "$NODE" ]; then
      send_email "$NODE" "$USAGE"
      log "INFO" "Email sent (Node=$NODE, Memory=$USAGE%)"
    else
      log "ERROR" "No node info available to send email."
    fi
  else
    log "DEBUG" "Memory precheck email skipped due to cooldown."
  fi
}

log "DEBUG" "Running checkmemory_precheck.sh"

if retry_with_config check_memory "$RETRY_COUNT" "$RETRY_INTERVAL"; then
  log "DEBUG" "Memory usage under control (precheck)."
  exit 0
else
  log "ERROR" "Memory still high after retries (precheck)."
  on_persisting_high_memory
  exit 0
fi
```

---

### 5.5 charts/memory-precheck/templates/all.yaml

```yaml
{{- define "memory-precheck.fullname" -}}
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
  name: {{ include "memory-precheck.fullname" . }}-scripts
  namespace: {{ .Release.Namespace }}
data:
  config.env: |
    RETRY_COUNT={{ .Values.config.RETRY_COUNT }}
    RETRY_INTERVAL={{ .Values.config.RETRY_INTERVAL }}
    COOLDOWN_PERIOD={{ .Values.config.COOLDOWN_PERIOD }}
    MEMORY_THRESHOLD={{ .Values.config.MEMORY_THRESHOLD }}
    LOG_DIR={{ .Values.config.LOG_DIR }}

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

  checkmemory_precheck.sh: |
{{ .Files.Get "scripts/checkmemory_precheck.sh" | indent 4 }}

---
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "memory-precheck.fullname" . }}-smtp
  namespace: {{ .Release.Namespace }}
type: Opaque
stringData:
  SMTP_PASSWORD: {{ .Values.secrets.SMTP_PASSWORD | quote }}

---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "memory-precheck.fullname" . }}-state
  namespace: {{ .Release.Namespace }}
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: {{ .Values.persistence.state.size }}

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "memory-precheck.fullname" . }}-sa
  namespace: {{ .Release.Namespace }}

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: {{ include "memory-precheck.fullname" . }}-role
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get","list"]
- apiGroups: ["metrics.k8s.io"]
  resources: ["nodes"]
  verbs: ["get","list"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: {{ include "memory-precheck.fullname" . }}-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: {{ include "memory-precheck.fullname" . }}-role
subjects:
- kind: ServiceAccount
  name: {{ include "memory-precheck.fullname" . }}-sa
  namespace: {{ .Release.Namespace }}

---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: {{ include "memory-precheck.fullname" . }}-cron
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
          serviceAccountName: {{ include "memory-precheck.fullname" . }}-sa
          securityContext:
            runAsUser: 0
            runAsGroup: 0
            fsGroup: 0
          restartPolicy: OnFailure
          containers:
          - name: memory-precheck
            image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
            command: ["/bin/bash","-c"]
            args:
              - |
                set -e
                apt-get update && \
                apt-get install -y curl ca-certificates && \
                curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
                install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && \
                bash /opt/scripts/checkmemory_precheck.sh
            volumeMounts:
            - name: scripts
              subPath: checkmemory_precheck.sh
              mountPath: /opt/scripts/checkmemory_precheck.sh
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
              name: {{ include "memory-precheck.fullname" . }}-scripts
          - name: state
            persistentVolumeClaim:
              claimName: {{ include "memory-precheck.fullname" . }}-state
          - name: logs
            persistentVolumeClaim:
              claimName: {{ .Values.sharedLogsPVC.name }}
          - name: smtpsecret
            secret:
              secretName: {{ include "memory-precheck.fullname" . }}-smtp
```

---

## 6) Local test (Maintainer)

### 6.1 Lint + Install

```bash
cd ~/Emplay/self-heal-helm-repo/charts/memory-precheck
helm lint .

helm uninstall memory-precheck -n default 2>/dev/null || true
helm install memory-precheck . -n default --create-namespace \
  --set-string secrets.SMTP_PASSWORD="YOUR_SMTP_APP_PASSWORD"
```

Verify:

```bash
kubectl get cronjob -n default | grep memory-precheck
kubectl top nodes
```

### 6.2 Manual test run

```bash
JOB="memory-precheck-manual-$(date +%Y%m%d-%H%M%S)"
kubectl create job --from=cronjob/memory-precheck-memory-precheck-cron "$JOB" -n default

POD=$(kubectl get pods -n default -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n default -f "$POD"
```

---

## 7) View logs (logs-viewer)

```bash
kubectl exec -it -n default deploy/logs-viewer -- sh
ls -lh /opt/logs
tail -f /opt/logs/memoryprecheck_$(date +%Y-%m-%d).log
```

---

## 8) Troubleshooting

### 8.1 If `kubectl top nodes` fails

Metrics-server missing.
Minikube:

```bash
minikube addons enable metrics-server
```

### 8.2 If email fails: `curl: (67) Login denied`

* Use Gmail **App Password**
* `SMTP_USERNAME` must match the Gmail account that generated the app password

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
git add docs helm-repo charts/memory-precheck
git commit -m "Add memory-precheck chart + publish helm repo"
git push
```

Done ✅

````
