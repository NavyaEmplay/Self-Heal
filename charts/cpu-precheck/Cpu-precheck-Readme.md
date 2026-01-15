Here’s a **single beautiful, correct, safe, step-by-step README** for `cpu-precheck` that includes **ALL files (templates + scripts)** and also includes your **GitHub Pages publish steps** in the correct place.

Copy-paste this as:

`charts/cpu-precheck/cpu-precheck-Readme.md`

---

```md
# ✅ cpu-precheck Helm Chart (Self-Heal Precheck) — Full Guide + Full Files

This chart deploys a Kubernetes **CronJob** that runs **prechecks** for your self-heal setup:
- ✅ Can the pod run `kubectl`?
- ✅ Is **Metrics API** working (`kubectl top nodes`)?
- ✅ Does the **shared logs PVC** exist (`self-heal-logs-pvc`)?
- ✅ Writes logs to shared directory (`/opt/logs`)
- ✅ Optional email notification on failure (SMTP)

---

## 🔥 MOST IMPORTANT RULE (prevents your PVC error forever)

### ✅ Shared logs PVC must be created ONE TIME (outside Helm)
If one Helm release creates a PVC, another release cannot “take ownership” → you get:

`PVC exists and cannot be imported... meta.helm.sh/release-name must equal ...`

✅ Best practice:
- Create shared PVC **manually once** using `shared-logs-pvc.yaml`
- In **ALL charts**, set `sharedLogsPVC.enabled: false`
- Charts will only **mount** the PVC, never create it

> ✅ Fix for your current situation:  
> Your `cpu-usage` chart has `sharedLogsPVC.enabled: true`, so it created & owns the PVC.  
> Set it to `false`, delete/recreate the PVC once manually, then install both charts cleanly.

---

# ✅ README-1 (Maintainer): Create cpu-precheck chart + Files + Test + Publish Repo

## 🔹 Step 0: Repo structure expected

From repo root `~/Emplay/self-heal-helm-repo` you should have:

```

charts/
cpu-usage/
cpu-precheck/
docs/
helm-repo/
logs-viewer.yaml
shared-logs-pvc.yaml

````

---

## 🔹 Step 1: Create chart folders (if not already)

```bash
cd ~/Emplay/self-heal-helm-repo
mkdir -p charts/cpu-precheck/templates charts/cpu-precheck/scripts
````

---

## 🔹 Step 2: Add FULL cpu-precheck files (copy/paste exactly)

### ✅ 2.1 `charts/cpu-precheck/Chart.yaml`

```yaml
apiVersion: v2
name: cpu-precheck
description: Precheck CronJob for Self-Heal (metrics + PVC + kubectl validation)
type: application
version: 0.1.0
appVersion: "1.0.0"
```

---

### ✅ 2.2 `charts/cpu-precheck/values.yaml`

✅ Note: shared PVC is **NOT created** by this chart.

```yaml
schedule: "*/10 * * * *"

image:
  repository: python
  tag: 3.11-slim

config:
  RETRY_COUNT: "3"
  RETRY_INTERVAL: "10"

  LOG_DIR: "/opt/logs"
  SHARED_LOGS_PVC_NAME: "self-heal-logs-pvc"

  # Email (optional)
  EMAIL_ENABLED: "true"
  EMAIL_SUBJECT_PREFIX: "[Self-Heal][PRECHECK]"
  EMAIL_FROM: "qa_emplay@emplay.net"
  EMAIL_TO: "nandhini.s@emplay.net,navya.sri@emplay.net"
  SMTP_HOST: "smtp.gmail.com"
  SMTP_PORT: "587"
  SMTP_USERNAME: "qa_emplay@emplay.net"

secrets:
  SMTP_PASSWORD: ""

# ✅ BEST PRACTICE:
# Shared PVC must be created ONE TIME outside Helm (shared-logs-pvc.yaml)
sharedLogsPVC:
  enabled: false
  name: "self-heal-logs-pvc"
  size: 100Mi
  storageClassName: "standard"
```

---

### ✅ 2.3 `charts/cpu-precheck/scripts/utils.sh`

```bash
#!/bin/bash
set -euo pipefail

log() {
  # $1=LEVEL, $2=MESSAGE
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" | tee -a "$LOG_DIR/precheck_$(date '+%Y-%m-%d').log"
}

retry_with_config() {
  local cmd=$1 retries=$2 interval=$3 count=0
  until $cmd; do
    count=$((count+1))
    if [ $count -ge $retries ]; then
      return 1
    fi
    log "DEBUG" "Retry $count/$retries failed, sleeping $interval seconds..."
    sleep "$interval"
  done
  return 0
}

send_email() {
  local subject="$1"
  local body="$2"

  SMTP_PASSWORD="$(cat "${SMTP_PASSWORD_FILE:-/opt/secret/SMTP_PASSWORD}" 2>/dev/null || true)"

  if [ "${EMAIL_ENABLED:-false}" = "true" ]; then
    local SUBJECT="${EMAIL_SUBJECT_PREFIX:-[PRECHECK]} $subject"

    RCPT_ARGS=()
    for rcpt in $(echo "${EMAIL_TO:-}" | tr ',' ' '); do
      [ -n "$rcpt" ] && RCPT_ARGS+=( --mail-rcpt "$rcpt" )
    done

    if [ ${#RCPT_ARGS[@]} -eq 0 ]; then
      log "ERROR" "EMAIL_ENABLED=true but EMAIL_TO is empty"
      return 0
    fi

    curl --silent --show-error --fail \
      --url "smtp://${SMTP_HOST}:${SMTP_PORT}" \
      --ssl-reqd \
      --mail-from "${EMAIL_FROM}" \
      "${RCPT_ARGS[@]}" \
      --user "${SMTP_USERNAME}:${SMTP_PASSWORD}" \
      -T <(echo -e "From: ${EMAIL_FROM}\nTo: ${EMAIL_TO}\nSubject: ${SUBJECT}\n\n${body}") \
      && log "INFO" "Email sent successfully" \
      || log "ERROR" "Email send failed (check SMTP settings/app password)"
  fi
}
```

---

### ✅ 2.4 `charts/cpu-precheck/scripts/checkcpu_precheck.sh`

```bash
#!/bin/bash
set -euo pipefail

source /opt/config/config.env
source /opt/utils/utils.sh

# cleanup old logs (keep 7 days)
find "$LOG_DIR" -type f -name "precheck_*.log" -mtime +7 -delete || true

NAMESPACE="${POD_NAMESPACE:-default}"
PVC_NAME="${SHARED_LOGS_PVC_NAME:-self-heal-logs-pvc}"

precheck() {
  log "INFO" "Starting cpu-precheck..."
  log "INFO" "Namespace=$NAMESPACE | SharedPVC=$PVC_NAME | LogDir=$LOG_DIR"

  # 1) kubectl should exist
  if ! command -v kubectl >/dev/null 2>&1; then
    log "ERROR" "kubectl is missing"
    return 1
  fi
  log "INFO" "kubectl found"

  # 2) cluster reachable
  if ! kubectl version --client >/dev/null 2>&1; then
    log "ERROR" "kubectl client check failed"
    return 1
  fi
  if ! kubectl get nodes >/dev/null 2>&1; then
    log "ERROR" "Cannot access cluster (kubectl get nodes failed)"
    return 1
  fi
  log "INFO" "Cluster reachable"

  # 3) shared logs PVC must exist
  if ! kubectl get pvc "$PVC_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    log "ERROR" "Shared logs PVC not found: pvc/$PVC_NAME in ns/$NAMESPACE"
    return 1
  fi
  log "INFO" "Shared logs PVC exists: pvc/$PVC_NAME"

  # 4) metrics must work
  if ! kubectl top nodes >/dev/null 2>&1; then
    log "ERROR" "Metrics API not working: kubectl top nodes failed (metrics-server?)"
    return 1
  fi
  log "INFO" "Metrics API OK (kubectl top nodes works)"

  log "INFO" "✅ cpu-precheck PASSED"
  return 0
}

if retry_with_config precheck "${RETRY_COUNT:-3}" "${RETRY_INTERVAL:-10}"; then
  exit 0
else
  log "ERROR" "❌ cpu-precheck FAILED after retries"
  send_email "Precheck FAILED" \
    "cpu-precheck failed in namespace=$NAMESPACE. Check logs in $LOG_DIR (precheck_$(date '+%Y-%m-%d').log)."
  exit 0
fi
```

---

### ✅ 2.5 `charts/cpu-precheck/templates/all.yaml` (single file)

```yaml
{{/*
Helpers inside all.yaml (no _helpers.tpl needed)
*/}}

{{- define "cpu-precheck.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cpu-precheck.fullname" -}}
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
  name: {{ include "cpu-precheck.fullname" . }}-scripts
  namespace: {{ .Release.Namespace }}
data:
  config.env: |
    RETRY_COUNT={{ .Values.config.RETRY_COUNT }}
    RETRY_INTERVAL={{ .Values.config.RETRY_INTERVAL }}
    LOG_DIR={{ .Values.config.LOG_DIR }}
    SHARED_LOGS_PVC_NAME={{ .Values.config.SHARED_LOGS_PVC_NAME }}

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

  checkcpu_precheck.sh: |
{{ .Files.Get "scripts/checkcpu_precheck.sh" | indent 4 }}

---
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "cpu-precheck.fullname" . }}-smtp
  namespace: {{ .Release.Namespace }}
type: Opaque
stringData:
  SMTP_PASSWORD: {{ .Values.secrets.SMTP_PASSWORD | quote }}

{{- if .Values.sharedLogsPVC.enabled }}
---
# ⚠️ Not recommended to enable in cpu-precheck.
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
  name: {{ include "cpu-precheck.fullname" . }}-sa
  namespace: {{ .Release.Namespace }}

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: {{ include "cpu-precheck.fullname" . }}-role
rules:
- apiGroups: [""]
  resources: ["nodes","persistentvolumeclaims"]
  verbs: ["get","list"]
- apiGroups: ["metrics.k8s.io"]
  resources: ["nodes"]
  verbs: ["get","list"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: {{ include "cpu-precheck.fullname" . }}-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: {{ include "cpu-precheck.fullname" . }}-role
subjects:
- kind: ServiceAccount
  name: {{ include "cpu-precheck.fullname" . }}-sa
  namespace: {{ .Release.Namespace }}

---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: {{ include "cpu-precheck.fullname" . }}-cron
  namespace: {{ .Release.Namespace }}
spec:
  schedule: {{ .Values.schedule | quote }}
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 1
      ttlSecondsAfterFinished: 300
      template:
        spec:
          serviceAccountName: {{ include "cpu-precheck.fullname" . }}-sa
          restartPolicy: OnFailure
          containers:
          - name: cpu-precheck
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
                bash /opt/scripts/checkcpu_precheck.sh
            volumeMounts:
            - name: scripts
              subPath: checkcpu_precheck.sh
              mountPath: /opt/scripts/checkcpu_precheck.sh
            - name: scripts
              subPath: config.env
              mountPath: /opt/config/config.env
            - name: scripts
              subPath: utils.sh
              mountPath: /opt/utils/utils.sh
            - name: logs
              mountPath: /opt/logs
            - name: smtpsecret
              mountPath: /opt/secret
              readOnly: true
          volumes:
          - name: scripts
            configMap:
              name: {{ include "cpu-precheck.fullname" . }}-scripts
          - name: logs
            persistentVolumeClaim:
              claimName: {{ .Values.config.SHARED_LOGS_PVC_NAME }}
          - name: smtpsecret
            secret:
              secretName: {{ include "cpu-precheck.fullname" . }}-smtp
```

---

## 🔹 Step 3: One-time cluster setup (shared PVC + logs-viewer)

### ✅ 3.1 shared-logs-pvc.yaml (repo root, ONE TIME)

`~/Emplay/self-heal-helm-repo/shared-logs-pvc.yaml`

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: self-heal-logs-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Mi
  storageClassName: standard
```

Apply once:

```bash
cd ~/Emplay/self-heal-helm-repo
kubectl apply -f shared-logs-pvc.yaml
kubectl get pvc -n default | grep self-heal-logs-pvc
```

### ✅ 3.2 logs-viewer.yaml (repo root, ONE TIME)

`~/Emplay/self-heal-helm-repo/logs-viewer.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: logs-viewer
  namespace: default
  labels:
    app: logs-viewer
spec:
  replicas: 1
  selector:
    matchLabels:
      app: logs-viewer
  template:
    metadata:
      labels:
        app: logs-viewer
    spec:
      containers:
      - name: viewer
        image: busybox:1.36
        command: ["sh","-c","sleep 365000d"]
        volumeMounts:
        - name: logs
          mountPath: /opt/logs
      volumes:
      - name: logs
        persistentVolumeClaim:
          claimName: self-heal-logs-pvc
```

Apply once:

```bash
kubectl apply -f logs-viewer.yaml
kubectl get pods -n default -l app=logs-viewer
```

---

## 🔹 Step 4: Fix CPU-USAGE chart to avoid PVC ownership conflict

In `charts/cpu-usage/values.yaml` set:

```yaml
sharedLogsPVC:
  enabled: false
  name: "self-heal-logs-pvc"
  size: 100Mi
  storageClassName: "standard"
```

> Your `cpu-usage/templates/all.yaml` already has `{{- if .Values.sharedLogsPVC.enabled }}` so this is enough.

✅ If the PVC was already created by cpu-usage Helm release and you want a clean setup:

```bash
kubectl delete deployment logs-viewer -n default 2>/dev/null || true
kubectl delete pvc self-heal-logs-pvc -n default 2>/dev/null || true

kubectl apply -f shared-logs-pvc.yaml
kubectl apply -f logs-viewer.yaml
```

---

## 🔹 Step 5: Lint + Install + Manual test cpu-precheck

```bash
cd ~/Emplay/self-heal-helm-repo/charts/cpu-precheck
helm lint .
```

Install:

```bash
helm uninstall cpu-precheck -n default 2>/dev/null || true

helm install cpu-precheck . -n default --create-namespace \
  --set-string secrets.SMTP_PASSWORD="YOUR_SMTP_APP_PASSWORD"
```

Manual run now (no waiting):

```bash
JOB="cpu-precheck-manual-$(date +%Y%m%d-%H%M%S)"
kubectl create job --from=cronjob/cpu-precheck-cpu-precheck-cron "$JOB" -n default

POD=$(kubectl get pods -n default -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n default -f "$POD"
```

Check logs from viewer:

```bash
kubectl exec -it -n default deploy/logs-viewer -- sh
ls -lh /opt/logs
tail -f /opt/logs/precheck_$(date +%Y-%m-%d).log
```

---

# ✅ Publish BOTH charts to GitHub Pages (docs/) — Your exact safe steps

## 🔹 Step 1: Go back to repo root

```bash
cd ~/Emplay/self-heal-helm-repo
ls
```

You should see:

```
charts  docs  helm-repo  logs-viewer.yaml  shared-logs-pvc.yaml
```

## 🔹 Step 2: Clean build folder

```bash
rm -rf helm-repo/*
```

## 🔹 Step 3: Package ALL charts (IMPORTANT: run from repo root only)

```bash
for d in charts/*; do
  [ -d "$d" ] && helm package "$d" -d helm-repo
done
```

Verify:

```bash
ls helm-repo
```

Expected:

```
cpu-usage-0.1.0.tgz
cpu-precheck-0.1.0.tgz
```

## 🔹 Step 4: Create index.yaml (correct path)

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
index.yaml
```

## 🔹 Step 5: Publish to GitHub Pages (docs/)

```bash
rm -rf docs/*
cp -r helm-repo/* docs/
```

Verify:

```bash
ls docs
```

## 🔹 Step 6: Commit & push

```bash
git add docs helm-repo
git commit -m "Publish cpu-usage and cpu-precheck Helm charts"
git push
```

---

