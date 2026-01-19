


---

## ✅ README-1 (Maintainer)


````md
# disk-usage Helm Chart (Self-Heal Disk Monitoring) — Maintainer Guide

This chart deploys a Kubernetes **CronJob** that checks **node disk usage** (root filesystem `/`) across all nodes.

✅ Uses your working approach:
- `kubectl debug node/<node>` to create a temporary debugger pod
- `chroot /host df -P /` inside that pod to read the **host disk usage**
- Logs written to shared logs PVC: `self-heal-logs-pvc`
- Optional email alerts when disk usage exceeds threshold
- Logs viewable via logs-viewer pod

---

## 0) What you will build

A Helm chart `disk-usage` that:
- runs on a Cron schedule (default: every 10 mins)
- checks disk usage on each node (`/` on host)
- writes logs into shared logs PVC
- keeps state in a small PVC (cooldown tracking)
- emails if above threshold (optional)

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

### 1.4 Minikube (for local testing)

```bash
sudo apt-get install -y docker.io
sudo usermod -aG docker $USER
newgrp docker

curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube
minikube version

minikube start --driver=docker
kubectl get nodes
```

---


## 3) Create chart structure

From repo root:

```bash
mkdir -p charts/disk-usage/templates charts/disk-usage/scripts
```

Expected:

```
charts/disk-usage/
├─ Chart.yaml
├─ values.yaml
├─ templates/
│  └─ all.yaml
└─ scripts/
   ├─ checkdisk.sh
   └─ utils.sh
```

---

## 4) Add ALL chart files (copy/paste exactly)

### 4.1 charts/disk-usage/Chart.yaml

```yaml
apiVersion: v2
name: disk-usage
description: Self-heal Disk monitoring CronJob (df / on host via kubectl debug + chroot)
type: application
version: 0.1.0
appVersion: "1.0.0"
```

### 4.2 charts/disk-usage/values.yaml

```yaml
schedule: "*/10 * * * *"

image:
  repository: python
  tag: 3.11-slim

config:
  RETRY_COUNT: "3"
  RETRY_INTERVAL: "10"
  COOLDOWN_PERIOD: "7200"
  DISK_THRESHOLD: "75"
  LOG_DIR: "/opt/logs"

  EMAIL_ENABLED: "true"
  EMAIL_SUBJECT_PREFIX: "[Self-Heal][Disk]"
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

# Shared logs PVC must be created ONE TIME outside Helm (recommended)
sharedLogsPVC:
  enabled: false
  name: "self-heal-logs-pvc"
  size: 100Mi
  storageClassName: "standard"
```

### 4.3 charts/disk-usage/scripts/utils.sh

```bash
#!/bin/bash

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" | tee -a "$LOG_DIR/diskcheck_$(date '+%Y-%m-%d').log"
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
  local node=$1
  local usage=$2

  SMTP_PASSWORD="$(cat "$SMTP_PASSWORD_FILE" 2>/dev/null || true)"

  if [ "$EMAIL_ENABLED" = "true" ]; then
    SUBJECT="$EMAIL_SUBJECT_PREFIX High Disk Alert on $node"
    BODY="ALERT: Node $node Disk=$usage% (Threshold=$DISK_THRESHOLD%)"

    RCPT_ARGS=()
    for rcpt in $(echo $EMAIL_TO | tr ',' ' '); do
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

### 4.4 charts/disk-usage/scripts/checkdisk.sh

```bash
#!/bin/bash
set -euo pipefail

source /opt/config/config.env
source /opt/utils/utils.sh

mkdir -p "$LOG_DIR" /opt/state
find "$LOG_DIR" -type f -name "diskcheck_*.log" -mtime +7 -delete || true

NAMESPACE="${POD_NAMESPACE:-default}"

cleanup_all_debuggers() {
  for p in $(kubectl get pods -n "$NAMESPACE" -o name | grep '^pod/node-debugger-' || true); do
    kubectl delete -n "$NAMESPACE" "$p" --now >/dev/null 2>&1 || true
  done
}

create_debugger_for_node() {
  local node="$1"

  # Create debugger pod (non-interactive)
  kubectl debug "$node" --image=ubuntu:24.04 --quiet -- sleep 120 >/dev/null 2>&1 || true

  local base; base="$(basename "$node")"
  local pod=""

  for i in {1..30}; do
    pod="$(kubectl get pods -n "$NAMESPACE" -o name | grep "node-debugger-${base}-" | head -n1 || true)"
    if [ -n "$pod" ]; then
      kubectl wait -n "$NAMESPACE" --for=condition=Ready "$pod" --timeout=60s >/dev/null 2>&1 || true
      echo "${pod#pod/}"
      return 0
    fi
    sleep 2
  done
  return 1
}

check_disk() {
  log "DEBUG" "Checking disk usage across all nodes (df / on host via kubectl debug)..."
  cleanup_all_debuggers

  alert=0
  max_usage=0
  max_node=""
  total_count=0

  for node in $(kubectl get nodes -o name); do
    base="$(basename "$node")"

    podname="$(create_debugger_for_node "$node" || true)"
    if [ -z "${podname:-}" ]; then
      log "ERROR" "Failed to create debugger for $node"
      continue
    fi

    usage="$(kubectl exec -n "$NAMESPACE" "$podname" -- chroot /host bash -c \
      "df -P / | awk 'NR==2 {print \$5}'" 2>/dev/null | grep -Eo '[0-9]+%' | head -n1 || true)"

    kubectl delete pod -n "$NAMESPACE" "$podname" --now >/dev/null 2>&1 || true

    if [ -z "$usage" ]; then
      log "ERROR" "Could not fetch disk usage for node $base"
      continue
    fi

    percent="${usage%\%}"
    total_count=$((total_count+1))

    if [ "$percent" -ge "$DISK_THRESHOLD" ]; then
      log "WARNING" "Node $base is above threshold: ${usage}"
      alert=1
    else
      log "INFO" "Node $base is healthy: ${usage}"
    fi

    if [ "$percent" -gt "$max_usage" ]; then
      max_usage=$percent
      max_node=$base
    fi
  done

  echo "${max_node:-}" > /opt/state/max_node
  echo "${max_usage:-0}" > /opt/state/max_usage

  if [ $alert -eq 0 ]; then
    log "INFO" "All $total_count nodes healthy. Highest usage=${max_usage}% on ${max_node}"
  else
    log "ERROR" "High Disk detected. Worst=${max_usage}% on ${max_node}"
  fi

  return $alert
}

if retry_with_config check_disk "$RETRY_COUNT" "$RETRY_INTERVAL"; then
  exit 0
else
  if can_alert "$COOLDOWN_PERIOD"; then
    NODE=$(cat /opt/state/max_node 2>/dev/null || echo "")
    USAGE=$(cat /opt/state/max_usage 2>/dev/null || echo "0")
    if [ -n "$NODE" ]; then
      send_email "$NODE" "$USAGE"
      log "INFO" "Email sent (Node=$NODE, Usage=$USAGE%)"
    fi
  fi
  exit 0
fi
```

### 4.5 charts/disk-usage/templates/all.yaml

```yaml
{{/*
Helpers inside all.yaml (no _helpers.tpl needed)
*/}}

{{- define "disk-usage.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "disk-usage.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "disk-usage.fullname" . }}-scripts
  namespace: {{ .Release.Namespace }}
data:
  config.env: |
    RETRY_COUNT={{ .Values.config.RETRY_COUNT }}
    RETRY_INTERVAL={{ .Values.config.RETRY_INTERVAL }}
    COOLDOWN_PERIOD={{ .Values.config.COOLDOWN_PERIOD }}
    DISK_THRESHOLD={{ .Values.config.DISK_THRESHOLD }}
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

  checkdisk.sh: |
{{ .Files.Get "scripts/checkdisk.sh" | indent 4 }}

---
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "disk-usage.fullname" . }}-smtp
  namespace: {{ .Release.Namespace }}
type: Opaque
stringData:
  SMTP_PASSWORD: {{ .Values.secrets.SMTP_PASSWORD | quote }}

---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "disk-usage.fullname" . }}-state
  namespace: {{ .Release.Namespace }}
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: {{ .Values.persistence.state.size }}

{{- if .Values.sharedLogsPVC.enabled }}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ .Values.sharedLogsPVC.name }}
  namespace: {{ .Release.Namespace }}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: {{ .Values.sharedLogsPVC.storageClassName | quote }}
  resources:
    requests:
      storage: {{ .Values.sharedLogsPVC.size }}
{{- end }}

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "disk-usage.fullname" . }}-sa
  namespace: {{ .Release.Namespace }}

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: {{ include "disk-usage.fullname" . }}-role
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get","list"]
- apiGroups: [""]
  resources: ["pods","pods/exec","pods/attach","pods/log"]
  verbs: ["get","list","create","delete","watch","patch","update"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: {{ include "disk-usage.fullname" . }}-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: {{ include "disk-usage.fullname" . }}-role
subjects:
- kind: ServiceAccount
  name: {{ include "disk-usage.fullname" . }}-sa
  namespace: {{ .Release.Namespace }}

---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: {{ include "disk-usage.fullname" . }}-cron
  namespace: {{ .Release.Namespace }}
spec:
  schedule: {{ .Values.schedule | quote }}
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 600
      ttlSecondsAfterFinished: 300
      template:
        spec:
          serviceAccountName: {{ include "disk-usage.fullname" . }}-sa
          restartPolicy: OnFailure
          containers:
          - name: disk-usage
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
                apt-get update && apt-get install -y curl ca-certificates && \
                curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
                install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && \
                bash /opt/scripts/checkdisk.sh
            volumeMounts:
            - name: scripts
              subPath: checkdisk.sh
              mountPath: /opt/scripts/checkdisk.sh
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
              name: {{ include "disk-usage.fullname" . }}-scripts
          - name: state
            persistentVolumeClaim:
              claimName: {{ include "disk-usage.fullname" . }}-state
          - name: logs
            persistentVolumeClaim:
              claimName: {{ .Values.sharedLogsPVC.name }}
          - name: smtpsecret
            secret:
              secretName: {{ include "disk-usage.fullname" . }}-smtp
```

---

## 5) Local test (Maintainer)

### 5.1 Lint + install chart

```bash
cd ~/Emplay/self-heal-helm-repo/charts/disk-usage
helm lint .

helm uninstall disk-usage -n default 2>/dev/null || true
helm install disk-usage . -n default --create-namespace \
  --set-string secrets.SMTP_PASSWORD="YOUR_SMTP_APP_PASSWORD"
```

Verify:

```bash
kubectl get cronjob -n default | grep disk-usage
kubectl get pvc -n default | grep -E "disk-usage|self-heal-logs-pvc"
```

### 5.2 Manual run test (don’t wait for cron)

```bash
JOB="disk-usage-manual-$(date +%Y%m%d-%H%M%S)"
kubectl create job --from=cronjob/disk-usage-disk-usage-cron "$JOB" -n default
POD=$(kubectl get pods -n default -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n default -f "$POD"
```

---

# ✅ Publish charts to GitHub Pages (docs/) — Your exact safe steps

## Step 1: Go back to repo root

```bash
cd ~/Emplay/self-heal-helm-repo
ls
```

You should see:

```
charts  docs  helm-repo  logs-viewer.yaml  shared-logs-pvc.yaml
```

## Step 2: Clean build folder

```bash
rm -rf helm-repo/*
```

## Step 3: Package ALL charts (IMPORTANT: run from repo root only)

```bash
for d in charts/*; do
  [ -d "$d" ] && helm package "$d" -d helm-repo
done
```

Verify:

```bash
ls helm-repo
```

Expected example:

```
cpu-usage-0.1.0.tgz
cpu-precheck-0.1.0.tgz
disk-usage-0.1.0.tgz
```

## Step 4: Create index.yaml (correct path)

```bash
helm repo index helm-repo \
  --url https://NavyaEmplay.github.io/Self-Heal
```

Verify:

```bash
ls helm-repo
```

Expected:

```
cpu-usage-0.1.0.tgz
cpu-precheck-0.1.0.tgz
disk-usage-0.1.0.tgz
index.yaml
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
git add docs helm-repo
git commit -m "Publish cpu-usage, cpu-precheck, and disk-usage Helm charts"
git push
```

Done ✅

```

---

