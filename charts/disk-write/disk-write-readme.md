
---

# ✅ README-1 (Maintainer) — disk-write (UPDATED with manual verification steps)


````md
# disk-write Helm Chart (Self-Heal Disk Write Monitoring) — Maintainer Guide

This chart deploys a Kubernetes **CronJob** that verifies each node can **write to disk** by creating a small test file under host `/tmp`.

✅ Host `/tmp` mounted into container as `/host/tmp` (hostPath)  
✅ Writes a test file (`echo "test" > /host/tmp/<file>`)  
✅ Logs written to shared logs PVC (`self-heal-logs-pvc`)  
✅ Retry + cooldown + optional email alert (same approach as disk-usage)  
✅ If `KEEP_FILE=1`, file stays for manual verification

---

## 0) What we are actually testing

We are testing **node disk write capability** (basic filesystem write) on the node where the job runs.

How:
- CronJob pod mounts node `/tmp` using **hostPath**
- Script writes a test file into `/host/tmp` (which is node `/tmp`)
- If write fails → retries `RETRY_COUNT` times
- If still failing → sends email (if enabled) but only once per `COOLDOWN_PERIOD`

This detects:
- read-only filesystem /tmp
- permission failures
- node storage issues causing write failures

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

### 2.1 shared logs PVC (ONE TIME)

From repo root:

```bash
cd ~/Emplay/self-heal-helm-repo
kubectl apply -f shared-logs-pvc.yaml
kubectl get pvc -n default | grep self-heal-logs-pvc
```

✅ Make sure `shared-logs-pvc.yaml` has:

```yaml
storageClassName: standard
```

### 2.2 logs-viewer (ONE TIME)

```bash
kubectl apply -f logs-viewer.yaml
kubectl get pods -n default -l app=logs-viewer
```

---

## 3) Chart folder structure

From repo root:

```bash
mkdir -p charts/disk-write/templates charts/disk-write/scripts
```

Expected:

```
charts/disk-write/
├─ Chart.yaml
├─ values.yaml
├─ templates/
│  └─ all.yaml
└─ scripts/
   ├─ checkdiskwrite.sh
   └─ utils.sh
```

---

## 4) Add chart files (copy/paste)

### 4.1 charts/disk-write/Chart.yaml

```yaml
apiVersion: v2
name: disk-write
description: Self-heal Disk Write CronJob (writes test file to host /tmp + email alert)
type: application
version: 0.1.0
appVersion: "1.0.0"
```

### 4.2 charts/disk-write/values.yaml

```yaml
schedule: "0 */6 * * *"   # every 6 hours

image:
  repository: alpine
  tag: "3.20"

config:
  RETRY_COUNT: "3"
  RETRY_INTERVAL: "10"
  COOLDOWN_PERIOD: "7200"
  LOG_DIR: "/opt/logs"
  TEST_PATH: "/host/tmp"
  KEEP_FILE: "1"

  EMAIL_ENABLED: "true"
  EMAIL_SUBJECT_PREFIX: "[Self-Heal][DiskWrite]"
  EMAIL_FROM: "qa_emplay@emplay.net"
  EMAIL_TO: "nandhini.s@emplay.net,navya.sri@emplay.net"
  SMTP_HOST: "smtp.gmail.com"
  SMTP_PORT: "587"
  SMTP_USERNAME: "qa_emplay@emplay.net"

secrets:
  SMTP_PASSWORD: ""   # set during helm install

persistence:
  state:
    size: 5Mi

sharedLogsPVC:
  name: "self-heal-logs-pvc"

hostTmp:
  hostPath: "/tmp"
```

### 4.3 charts/disk-write/scripts/utils.sh

```bash
#!/bin/bash

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" | tee -a "$LOG_DIR/diskwrite_$(date '+%Y-%m-%d').log"
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
  local msg=$2

  SMTP_PASSWORD="$(cat "$SMTP_PASSWORD_FILE" 2>/dev/null || true)"

  if [ "$EMAIL_ENABLED" = "true" ]; then
    SUBJECT="$EMAIL_SUBJECT_PREFIX Disk Write Alert on $node"
    BODY="ALERT: Disk write FAILED on node=$node\n$msg\nTestPath=$TEST_PATH\nTime=$(date)"

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

### 4.4 charts/disk-write/scripts/checkdiskwrite.sh

```bash
#!/bin/bash
set -euo pipefail

source /opt/config/config.env
source /opt/utils/utils.sh

mkdir -p "$LOG_DIR" /opt/state
find "$LOG_DIR" -type f -name "diskwrite_*.log" -mtime +7 -delete || true

check_disk_write() {
  log "DEBUG" "Checking disk write capability..."
  local f="$TEST_PATH/self_heal_disk_write_test_$$"

  if ! echo "test" > "$f" 2>/dev/null; then
    log "WARNING" "Disk write FAILED: could not write $f"
    echo "$NODE_NAME" > /opt/state/max_node 2>/dev/null || true
    echo "Disk write failed at $f" > /opt/state/fail_reason 2>/dev/null || true
    return 1
  fi

  if [ "${KEEP_FILE:-0}" = "1" ]; then
    log "INFO" "KEEP_FILE=1 → leaving $f for manual verification"
    sleep 60
  else
    rm -f "$f" 2>/dev/null || true
  fi

  log "INFO" "Disk write OK at $TEST_PATH (node: ${NODE_NAME:-unknown})"
  echo "$NODE_NAME" > /opt/state/max_node 2>/dev/null || true
  echo "OK" > /opt/state/fail_reason 2>/dev/null || true
  return 0
}

if retry_with_config check_disk_write "$RETRY_COUNT" "$RETRY_INTERVAL"; then
  exit 0
else
  log "ERROR" "Disk write issue persisted after retries."

  if can_alert "$COOLDOWN_PERIOD"; then
    NODE=$(cat /opt/state/max_node 2>/dev/null || echo "${NODE_NAME:-unknown}")
    REASON=$(cat /opt/state/fail_reason 2>/dev/null || echo "Disk write failed")
    send_email "$NODE" "$REASON"
    log "INFO" "Email sent (Node=$NODE)"
  fi

  exit 0
fi
```

### 4.5 charts/disk-write/templates/all.yaml

```yaml
{{- define "disk-write.fullname" -}}
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
  name: {{ include "disk-write.fullname" . }}-scripts
  namespace: {{ .Release.Namespace }}
data:
  config.env: |
    RETRY_COUNT={{ .Values.config.RETRY_COUNT }}
    RETRY_INTERVAL={{ .Values.config.RETRY_INTERVAL }}
    COOLDOWN_PERIOD={{ .Values.config.COOLDOWN_PERIOD }}
    LOG_DIR={{ .Values.config.LOG_DIR }}
    TEST_PATH={{ .Values.config.TEST_PATH }}
    KEEP_FILE={{ .Values.config.KEEP_FILE }}

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

  checkdiskwrite.sh: |
{{ .Files.Get "scripts/checkdiskwrite.sh" | indent 4 }}

---
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "disk-write.fullname" . }}-smtp
  namespace: {{ .Release.Namespace }}
type: Opaque
stringData:
  SMTP_PASSWORD: {{ .Values.secrets.SMTP_PASSWORD | quote }}

---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "disk-write.fullname" . }}-state
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
  name: {{ include "disk-write.fullname" . }}-sa
  namespace: {{ .Release.Namespace }}

---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: {{ include "disk-write.fullname" . }}-cron
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
          serviceAccountName: {{ include "disk-write.fullname" . }}-sa
          restartPolicy: OnFailure
          containers:
          - name: disk-write
            image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
            env:
              - name: NODE_NAME
                valueFrom:
                  fieldRef:
                    fieldPath: spec.nodeName
            command: ["/bin/sh","-c"]
            args:
              - |
                set -e
                apk add --no-cache bash coreutils curl
                bash /opt/scripts/checkdiskwrite.sh
            volumeMounts:
            - name: scripts
              subPath: checkdiskwrite.sh
              mountPath: /opt/scripts/checkdiskwrite.sh
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
            - name: host-tmp
              mountPath: /host/tmp
            - name: smtpsecret
              mountPath: /opt/secret
              readOnly: true
          volumes:
          - name: scripts
            configMap:
              name: {{ include "disk-write.fullname" . }}-scripts
          - name: state
            persistentVolumeClaim:
              claimName: {{ include "disk-write.fullname" . }}-state
          - name: logs
            persistentVolumeClaim:
              claimName: {{ .Values.sharedLogsPVC.name }}
          - name: host-tmp
            hostPath:
              path: {{ .Values.hostTmp.hostPath | quote }}
              type: Directory
          - name: smtpsecret
            secret:
              secretName: {{ include "disk-write.fullname" . }}-smtp
```

---

## 5) Install + run (Maintainer)

### 5.1 Lint + install

```bash
cd ~/Emplay/self-heal-helm-repo/charts/disk-write
helm lint .

helm uninstall disk-write -n default 2>/dev/null || true
helm install disk-write . -n default --create-namespace \
  --set-string secrets.SMTP_PASSWORD="YOUR_GMAIL_APP_PASSWORD"
```

Verify:

```bash
kubectl get cronjob -n default | grep disk-write
kubectl get pvc -n default | grep -E "disk-write|self-heal-logs-pvc"
```

### 5.2 Manual run (don’t wait for cron)

```bash
JOB="disk-write-manual-$(date +%Y%m%d-%H%M%S)"
kubectl create job --from=cronjob/disk-write-disk-write-cron "$JOB" -n default

POD=$(kubectl get pods -n default -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n default -f "$POD"
```

---

## 6) ✅ Manual verification (KEEP_FILE=1) — How to check the created file

### Option A (Recommended): Use a temporary debug pod on the SAME node

1. Find which node the job pod ran on:

```bash
kubectl get pod -n default "$POD" -o wide
```

Look at `NODE` column (example: `minikube`).

2. Create a small debug pod pinned to that node and mounting host `/tmp`:

```bash
NODE=$(kubectl get pod -n default "$POD" -o jsonpath='{.spec.nodeName}')

kubectl run diskwrite-check -n default --rm -it --image=alpine:3.20 --overrides='
{
  "apiVersion":"v1",
  "spec":{
    "nodeName":"'"$NODE"'",
    "containers":[{
      "name":"c",
      "image":"alpine:3.20",
      "command":["/bin/sh"],
      "stdin":true,
      "tty":true,
      "volumeMounts":[{"name":"host-tmp","mountPath":"/host/tmp"}]
    }],
    "volumes":[{"name":"host-tmp","hostPath":{"path":"/tmp","type":"Directory"}}]
  }
}'
```

3. Inside that shell:

```sh
ls -lh /host/tmp | grep self_heal_disk_write_test || true
cat /host/tmp/self_heal_disk_write_test_* 2>/dev/null || true
```

✅ This is the cleanest method and works in any cluster.

---

### Option B (Minikube only): Check directly inside the minikube VM

```bash
minikube ssh
ls -lh /tmp | grep self_heal_disk_write_test || true
cat /tmp/self_heal_disk_write_test_* 2>/dev/null || true
exit
```

---

## 7) View logs via logs-viewer

```bash
kubectl exec -it -n default deploy/logs-viewer -- sh
ls -lh /opt/logs
tail -f /opt/logs/diskwrite_$(date +%Y-%m-%d).log
```

---

# ✅ Publish charts to GitHub Pages (docs/) — Your safe steps

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

## Step 5: Publish to GitHub Pages (docs/)

```bash
rm -rf docs/*
cp -r helm-repo/* docs/
```

## Step 6: Commit & push

```bash
git add docs helm-repo charts/disk-write
git commit -m "Add disk-write chart + publish helm repo"
git push
```

Done ✅

````

---

