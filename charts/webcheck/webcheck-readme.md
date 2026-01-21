I’ll give you two paste-ready READMEs that include the full chart code blocks (Chart.yaml, values.yaml, templates/all.yaml, scripts) plus the exact install/test/log steps for running multiple URLs and avoiding the Helm ownership error.


Below are **2 complete paste-ready READMEs** for **webcheck (webdown)** that include **ALL CODES** (Chart.yaml, values.yaml, templates/all.yaml, scripts) + **step-by-step** install/test/logs + **multiple URLs (one CronJob per URL via separate Helm release)** + **delete old release before re-install** + **correct logs-viewer commands** (use `/logs/...`).

---

# ✅ README-1.md (Maintainer) — Full Code + Install + Multi-URL + Test + Publish

**Copy-paste this entire file as:**
`charts/webcheck/webcheck-Readme.md`

````md
# webcheck Helm Chart (Self-Heal Web Down Monitoring) — Maintainer Guide (FULL CODE)

This chart deploys a Kubernetes **CronJob** that checks a URL periodically.
If the URL is down after retries, it can:
✅ restart a Kubernetes Deployment (optional)  
✅ send email alert  
✅ write logs to shared logs PVC (`self-heal-logs-pvc`)  
✅ store cooldown/state in a small PVC per release  

✅ Supports multiple URLs by installing chart multiple times:
- `webcheck-botv2` → CronJob `webcheck-botv2-webcheck-cron` → logs `/logs/webcheck-botv2/`
- `webcheck-zingerx` → CronJob `webcheck-zingerx-webcheck-cron` → logs `/logs/webcheck-zingerx/`

---

## 0) Prerequisites

### Tools
```bash
sudo apt-get update -y
sudo apt-get install -y git curl ca-certificates
````

### Helm

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

### kubectl

```bash
curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client
```

### Cluster ready

```bash
kubectl get nodes
```

(Optional: minikube)

```bash
minikube start --driver=docker
kubectl get nodes
```

---

## 1) One-time cluster setup (Shared logs PVC + logs-viewer)

> These are shared for ALL charts (cpu/disk/memory/webcheck).

From repo root:

```bash
cd ~/Emplay/self-heal-helm-repo
```

### 1.1 Apply shared logs PVC

```bash
kubectl apply -f shared-logs-pvc.yaml
kubectl get pvc -n default | grep self-heal-logs-pvc
```

### 1.2 Apply logs-viewer

```bash
kubectl apply -f logs-viewer.yaml
kubectl get pods -n default -l app=logs-viewer
```

---

## 2) Create chart folders

From repo root:

```bash
mkdir -p charts/webcheck/templates charts/webcheck/scripts
```

Expected:

```
charts/webcheck/
├─ Chart.yaml
├─ values.yaml
├─ templates/
│  └─ all.yaml
└─ scripts/
   ├─ utils.sh
   └─ checkwebdown.sh
```

---

## 3) ✅ FULL CHART CODE (copy/paste exactly)

### 3.1 charts/webcheck/Chart.yaml

```yaml
apiVersion: v2
name: webcheck
description: Self-Heal WebDown monitor (curl URL + optional deployment restart + email + logs)
type: application
version: 0.1.0
appVersion: "1.0.0"
```

---

### 3.2 charts/webcheck/values.yaml (public image only)

✅ Use public image (no Azure, no ECR auth needed).

```yaml
schedule: "*/2 * * * *"

image:
  repository: debian
  tag: bullseye-slim
  pullPolicy: IfNotPresent

config:
  URL_TO_CHECK: "http://test-webapp-service:5678"
  TIMEOUT_DURATION: "5"
  RETRY_COUNT: "3"
  RETRY_INTERVAL: "2"
  COOLDOWN_PERIOD: "300"

  # Optional restart
  WEB_DEPLOYMENT_NAME: "test-webapp"
  WEB_DEPLOYMENT_NAMESPACE: "default"

  # IMPORTANT: logs-viewer mounts PVC at /logs
  # We will set this per release during install: /logs/webcheck-botv2 , /logs/webcheck-zingerx etc.
  LOG_DIR: "/logs/webcheck"

  EMAIL_ENABLED: "true"
  EMAIL_SUBJECT_PREFIX: "[Self-Heal][WebApp]"
  EMAIL_FROM: "qa_emplay@emplay.net"
  EMAIL_TO: "nandhini.s@emplay.net,navya.sri@emplay.net"
  SMTP_HOST: "smtp.gmail.com"
  SMTP_PORT: "587"
  SMTP_USERNAME: "qa_emplay@emplay.net"

secrets:
  SMTP_PASSWORD: ""   # pass at install time

persistence:
  state:
    size: 1Mi

sharedLogsPVC:
  name: "self-heal-logs-pvc"

# Optional: deploy test webapp from this chart (ONLY for testing)
testWebApp:
  enabled: true
```

---

### 3.3 charts/webcheck/scripts/utils.sh

```bash
#!/bin/bash

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" | tee -a "$LOG_DIR/webcheck_$(date '+%Y-%m-%d').log"
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

can_restart() {
  local cooldown=$1 file=/opt/state/last_restart now=$(date +%s)
  if [ -f $file ]; then
    last=$(<$file)
    if (( last + cooldown > now )); then
      remain=$(( last + cooldown - now ))
      log "INFO" "⏳ Cooldown active, skipping restart (wait ${remain}s more)"
      return 1
    fi
  fi
  echo $now > $file
  return 0
}

send_email() {
  local subject="$1"
  local body="$2"

  SMTP_PASSWORD="$(cat "$SMTP_PASSWORD_FILE" 2>/dev/null || true)"

  if [ "$EMAIL_ENABLED" = "true" ]; then
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
      -T <(echo -e "From: $EMAIL_FROM\nTo: $EMAIL_TO\nSubject: $subject\n\n$body")
  fi
}
```

---

### 3.4 charts/webcheck/scripts/checkwebdown.sh

```bash
#!/bin/bash
set -euo pipefail

source /opt/config/config.env
source /opt/utils/utils.sh

mkdir -p "$LOG_DIR" /opt/state

# Cleanup logs older than 7 days
find "$LOG_DIR" -type f -name "webcheck_*.log" -mtime +7 -delete || true

check_web() {
  log "DEBUG" "Checking $URL_TO_CHECK"
  code=$(curl -s -o /dev/null -w "%{http_code}" -L --max-time "$TIMEOUT_DURATION" "$URL_TO_CHECK" || true)

  if [[ "$code" =~ ^2|3 ]]; then
    log "INFO" "✅ Service healthy (HTTP $code)"
    return 0
  else
    log "WARNING" "❌ Service unhealthy (HTTP $code)"
    return 1
  fi
}

restart_service() {
  if can_restart "$COOLDOWN_PERIOD"; then
    log "ERROR" "Restarting Deployment $WEB_DEPLOYMENT_NAME in namespace $WEB_DEPLOYMENT_NAMESPACE"
    kubectl rollout restart deployment "$WEB_DEPLOYMENT_NAME" -n "$WEB_DEPLOYMENT_NAMESPACE" || true

    send_email \
      "$EMAIL_SUBJECT_PREFIX Web service restarted" \
      "[$(date '+%Y-%m-%d %H:%M:%S')] Restarted $WEB_DEPLOYMENT_NAME because $URL_TO_CHECK was down."

    log "INFO" "✅ Job completed successfully (restart triggered)"
  else
    log "INFO" "✅ Job completed successfully (restart skipped due to cooldown)"
  fi
}

if retry_with_config check_web "$RETRY_COUNT" "$RETRY_INTERVAL"; then
  log "INFO" "✅ Job completed successfully (service healthy)"
  exit 0
else
  log "ERROR" "Web service seems down, attempting restart"
  restart_service
  exit 0
fi
```

---

### 3.5 charts/webcheck/templates/all.yaml

```yaml
{{- define "webcheck.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "webcheck.fullname" . }}-scripts
  namespace: {{ .Release.Namespace }}
data:
  config.env: |
    URL_TO_CHECK={{ .Values.config.URL_TO_CHECK | quote }}
    TIMEOUT_DURATION={{ .Values.config.TIMEOUT_DURATION | quote }}
    RETRY_COUNT={{ .Values.config.RETRY_COUNT | quote }}
    RETRY_INTERVAL={{ .Values.config.RETRY_INTERVAL | quote }}
    COOLDOWN_PERIOD={{ .Values.config.COOLDOWN_PERIOD | quote }}

    WEB_DEPLOYMENT_NAME={{ .Values.config.WEB_DEPLOYMENT_NAME | quote }}
    WEB_DEPLOYMENT_NAMESPACE={{ .Values.config.WEB_DEPLOYMENT_NAMESPACE | quote }}

    LOG_DIR={{ .Values.config.LOG_DIR | quote }}

    EMAIL_ENABLED={{ .Values.config.EMAIL_ENABLED | quote }}
    EMAIL_SUBJECT_PREFIX={{ .Values.config.EMAIL_SUBJECT_PREFIX | quote }}
    EMAIL_FROM={{ .Values.config.EMAIL_FROM | quote }}
    EMAIL_TO={{ .Values.config.EMAIL_TO | quote }}
    SMTP_HOST={{ .Values.config.SMTP_HOST | quote }}
    SMTP_PORT={{ .Values.config.SMTP_PORT | quote }}
    SMTP_USERNAME={{ .Values.config.SMTP_USERNAME | quote }}
    SMTP_PASSWORD_FILE=/opt/secret/SMTP_PASSWORD

  utils.sh: |
{{ .Files.Get "scripts/utils.sh" | indent 4 }}

  checkwebdown.sh: |
{{ .Files.Get "scripts/checkwebdown.sh" | indent 4 }}

---
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "webcheck.fullname" . }}-smtp
  namespace: {{ .Release.Namespace }}
type: Opaque
stringData:
  SMTP_PASSWORD: {{ .Values.secrets.SMTP_PASSWORD | quote }}

---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "webcheck.fullname" . }}-state
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
  name: {{ include "webcheck.fullname" . }}-sa
  namespace: {{ .Release.Namespace }}

---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ include "webcheck.fullname" . }}-role
  namespace: {{ .Release.Namespace }}
rules:
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get","list","patch"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ include "webcheck.fullname" . }}-binding
  namespace: {{ .Release.Namespace }}
subjects:
- kind: ServiceAccount
  name: {{ include "webcheck.fullname" . }}-sa
  namespace: {{ .Release.Namespace }}
roleRef:
  kind: Role
  name: {{ include "webcheck.fullname" . }}-role
  apiGroup: rbac.authorization.k8s.io

---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: {{ include "webcheck.fullname" . }}-cron
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
          serviceAccountName: {{ include "webcheck.fullname" . }}-sa
          restartPolicy: OnFailure
          containers:
          - name: webcheck
            image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
            imagePullPolicy: {{ .Values.image.pullPolicy }}
            command: ["/bin/bash","-c"]
            args:
              - |
                set -e
                apt-get update && apt-get install -y curl ca-certificates && \
                bash /opt/scripts/checkwebdown.sh
            volumeMounts:
            - name: scripts
              subPath: checkwebdown.sh
              mountPath: /opt/scripts/checkwebdown.sh
            - name: scripts
              subPath: config.env
              mountPath: /opt/config/config.env
            - name: scripts
              subPath: utils.sh
              mountPath: /opt/utils/utils.sh
            - name: cooldown
              mountPath: /opt/state
            - name: logs
              mountPath: /logs
            - name: smtpsecret
              mountPath: /opt/secret
              readOnly: true
          volumes:
          - name: scripts
            configMap:
              name: {{ include "webcheck.fullname" . }}-scripts
          - name: cooldown
            persistentVolumeClaim:
              claimName: {{ include "webcheck.fullname" . }}-state
          - name: logs
            persistentVolumeClaim:
              claimName: {{ .Values.sharedLogsPVC.name }}
          - name: smtpsecret
            secret:
              secretName: {{ include "webcheck.fullname" . }}-smtp
          tolerations:
          - operator: "Exists"

{{- if .Values.testWebApp.enabled }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-webapp
  namespace: {{ .Release.Namespace }}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-webapp
  template:
    metadata:
      labels:
        app: test-webapp
    spec:
      containers:
      - name: test-webapp
        image: hashicorp/http-echo
        args:
        - "-text=Hello! Test app is up."
        ports:
        - containerPort: 5678

---
apiVersion: v1
kind: Service
metadata:
  name: test-webapp-service
  namespace: {{ .Release.Namespace }}
spec:
  selector:
    app: test-webapp
  ports:
  - port: 5678
    targetPort: 5678
{{- end }}
```

---

## 4) Lint chart

```bash
cd ~/Emplay/self-heal-helm-repo/charts/webcheck
helm lint .
```

---

## 5) IMPORTANT: Avoid Helm ownership error (your issue)

Error you saw:

> Service "test-webapp-service" exists and cannot be imported...

✅ Fix rules:

1. Only keep **testWebApp enabled for ONE release** (example: release name `webcheck-test`)
2. For real URLs, always install with:

```bash
--set testWebApp.enabled=false
```

If you already created test-webapp with old release and want to clean:

```bash
helm uninstall webcheck -n default 2>/dev/null || true
kubectl delete svc test-webapp-service -n default 2>/dev/null || true
kubectl delete deploy test-webapp -n default 2>/dev/null || true
```

---

## 6) Install for URL-1 (BotV2) — one release = one CronJob

### 6.1 Delete old release first (safe)

```bash
helm uninstall webcheck-botv2 -n default 2>/dev/null || true
```

### 6.2 Install

```bash
cd ~/Emplay/self-heal-helm-repo

helm upgrade --install webcheck-botv2 charts/webcheck -n default --create-namespace \
  --set testWebApp.enabled=false \
  --set config.URL_TO_CHECK="https://dev.agent-botv2.zinger-emplay.net/" \
  --set config.WEB_DEPLOYMENT_NAME="botv2" \
  --set config.WEB_DEPLOYMENT_NAMESPACE="default" \
  --set config.LOG_DIR="/logs/webcheck-botv2" \
  --set-string secrets.SMTP_PASSWORD="YOUR_SMTP_APP_PASSWORD"
```

Verify:

```bash
kubectl get cronjob -n default | grep webcheck-botv2
```

---

## 7) Install for URL-2 (ZingerX)

### 7.1 Delete old release first (safe)

```bash
helm uninstall webcheck-zingerx -n default 2>/dev/null || true
```

### 7.2 Install

```bash
cd ~/Emplay/self-heal-helm-repo

helm upgrade --install webcheck-zingerx charts/webcheck -n default \
  --set testWebApp.enabled=false \
  --set config.URL_TO_CHECK="https://dev.zingerx.zinger-emplay.net/" \
  --set config.WEB_DEPLOYMENT_NAME="zingerx" \
  --set config.WEB_DEPLOYMENT_NAMESPACE="default" \
  --set config.LOG_DIR="/logs/webcheck-zingerx" \
  --set-string secrets.SMTP_PASSWORD="YOUR_SMTP_APP_PASSWORD"
```

Verify:

```bash
kubectl get cronjob -n default | grep webcheck-zingerx
```

---

## 8) Manual job run (one manual job per URL)

### BotV2 manual job

```bash
JOB="webcheck-botv2-manual-$(date +%Y%m%d-%H%M%S)"
kubectl create job --from=cronjob/webcheck-botv2-webcheck-cron "$JOB" -n default

POD=$(kubectl get pods -n default -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n default -f "$POD"
```

### ZingerX manual job

```bash
JOB="webcheck-zingerx-manual-$(date +%Y%m%d-%H%M%S)"
kubectl create job --from=cronjob/webcheck-zingerx-webcheck-cron "$JOB" -n default

POD=$(kubectl get pods -n default -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n default -f "$POD"
```

---

## 9) View logs in logs-viewer (✅ Corrected)

### Enter logs-viewer

```bash
kubectl exec -it -n default deploy/logs-viewer -- sh
```

### List folders

```sh
ls -lh /logs
ls -lh /logs/webcheck-botv2
ls -lh /logs/webcheck-zingerx
```

### Tail today logs (BotV2)

```sh
tail -f /logs/webcheck-botv2/webcheck_$(date +%Y-%m-%d).log
```

### Tail today logs (ZingerX)

```sh
tail -f /logs/webcheck-zingerx/webcheck_$(date +%Y-%m-%d).log
```

✅ Yes — both URLs logs are stored in same PVC but separated by folders:

* `/logs/webcheck-botv2/`
* `/logs/webcheck-zingerx/`

---

## 10) Publish ALL charts to GitHub Pages (docs/) — your exact safe steps

### Step 1: Go back to repo root

```bash
cd ~/Emplay/self-heal-helm-repo
ls
```

You should see:
`charts  docs  helm-repo  logs-viewer.yaml  shared-logs-pvc.yaml`

### Step 2: Clean build folder

```bash
rm -rf helm-repo/*
```

### Step 3: Package ALL charts (run from repo root only)

```bash
for d in charts/*; do
  [ -d "$d" ] && helm package "$d" -d helm-repo
done
ls helm-repo
```

### Step 4: Create index.yaml

```bash
helm repo index helm-repo \
  --url https://NavyaEmplay.github.io/Self-Heal
ls helm-repo
```

### Step 5: Publish to GitHub Pages folder (docs/)

```bash
rm -rf docs/*
cp -r helm-repo/* docs/
touch docs/.nojekyll
ls docs
```

### Step 6: Commit & push

```bash
git add docs helm-repo
git commit -m "Publish Helm charts (including webcheck)"
git push
```

GitHub: Settings → Pages → Deploy from branch `main` + folder `/docs`

Done ✅

````

---

# ✅ README-2.md (Tester/New VM) — Install from Repo → Run Jobs → Watch Logs

**Copy-paste this entire file as:**  
`charts/webcheck/test-Readme.md`

```md
# webcheck Helm Chart (Tester Guide)

This guide helps a new VM/user to:
✅ install helm + kubectl  
✅ add Helm repo (GitHub Pages)  
✅ install webcheck for multiple URLs (one release per URL = one CronJob)  
✅ manual test job per URL  
✅ view logs using logs-viewer  

---

## 1) Prerequisites
- Ubuntu VM
- Kubernetes cluster access
- kubectl configured

Check:
```bash
kubectl get nodes
````

---

## 2) Install tools (helm + kubectl)

```bash
sudo apt-get update -y
sudo apt-get install -y git curl ca-certificates

curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version

curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client
```

---

## 3) One-time setup: logs PVC + logs-viewer (required)

Clone repo (to apply yaml):

```bash
mkdir -p ~/test-self-heal
cd ~/test-self-heal
git clone https://github.com/NavyaEmplay/Self-Heal.git
cd Self-Heal
```

Apply shared logs PVC:

```bash
kubectl apply -f shared-logs-pvc.yaml
kubectl get pvc -n default | grep self-heal-logs-pvc
```

Apply logs-viewer:

```bash
kubectl apply -f logs-viewer.yaml
kubectl get pods -n default -l app=logs-viewer
```

---

## 4) Add Helm repo (GitHub Pages)

```bash
helm repo remove self-heal 2>/dev/null || true
helm repo add self-heal https://NavyaEmplay.github.io/Self-Heal
helm repo update
helm search repo self-heal
```

You should see:

* self-heal/webcheck

---

## 5) Install webcheck for URL-1 (BotV2 example)

✅ Always delete old release first:

```bash
helm uninstall webcheck-botv2 -n default 2>/dev/null || true
```

Install:

```bash
helm upgrade --install webcheck-botv2 self-heal/webcheck -n default --create-namespace \
  --set testWebApp.enabled=false \
  --set config.URL_TO_CHECK="https://dev.agent-botv2.zinger-emplay.net/" \
  --set config.WEB_DEPLOYMENT_NAME="botv2" \
  --set config.WEB_DEPLOYMENT_NAMESPACE="default" \
  --set config.LOG_DIR="/logs/webcheck-botv2" \
  --set-string secrets.SMTP_PASSWORD="YOUR_SMTP_APP_PASSWORD"
```

Verify:

```bash
kubectl get cronjob -n default | grep webcheck-botv2
```

---

## 6) Install webcheck for URL-2 (ZingerX example)

Delete old release:

```bash
helm uninstall webcheck-zingerx -n default 2>/dev/null || true
```

Install:

```bash
helm upgrade --install webcheck-zingerx self-heal/webcheck -n default \
  --set testWebApp.enabled=false \
  --set config.URL_TO_CHECK="https://dev.zingerx.zinger-emplay.net/" \
  --set config.WEB_DEPLOYMENT_NAME="zingerx" \
  --set config.WEB_DEPLOYMENT_NAMESPACE="default" \
  --set config.LOG_DIR="/logs/webcheck-zingerx" \
  --set-string secrets.SMTP_PASSWORD="YOUR_SMTP_APP_PASSWORD"
```

Verify:

```bash
kubectl get cronjob -n default | grep webcheck-zingerx
```

---

## 7) Manual test job (one job per URL)

### BotV2 manual test

```bash
JOB="webcheck-botv2-manual-$(date +%Y%m%d-%H%M%S)"
kubectl create job --from=cronjob/webcheck-botv2-webcheck-cron "$JOB" -n default

POD=$(kubectl get pods -n default -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n default -f "$POD"
```

### ZingerX manual test

```bash
JOB="webcheck-zingerx-manual-$(date +%Y%m%d-%H%M%S)"
kubectl create job --from=cronjob/webcheck-zingerx-webcheck-cron "$JOB" -n default

POD=$(kubectl get pods -n default -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n default -f "$POD"
```

---

## 8) Watch logs in logs-viewer (✅ Correct commands)

Enter logs-viewer:

```bash
kubectl exec -it -n default deploy/logs-viewer -- sh
```

List:

```sh
ls -lh /logs
ls -lh /logs/webcheck-botv2
ls -lh /logs/webcheck-zingerx
```

Tail BotV2 today:

```sh
tail -f /logs/webcheck-botv2/webcheck_$(date +%Y-%m-%d).log
```

Tail ZingerX today:

```sh
tail -f /logs/webcheck-zingerx/webcheck_$(date +%Y-%m-%d).log
```

✅ Yes — both logs stay in the same PVC, but separated into folders.

---

## 9) Cleanup (optional)

```bash
helm uninstall webcheck-botv2 -n default
helm uninstall webcheck-zingerx -n default
```

(Do not delete shared logs PVC / logs-viewer if other self-heal charts still use them.)

````

---

## Your exact “log issue” fix (why earlier tail failed)
- logs-viewer uses mount path: **/logs**
- your webcheck logs for botv2 are here:
  - `/logs/webcheck-botv2/webcheck_2026-01-21.log`
So the correct command is:
```sh
tail -f /logs/webcheck-botv2/webcheck_$(date +%Y-%m-%d).log
````

---

If you want, paste your current `logs-viewer.yaml` here once — I can also align it so it always shows `/logs` clearly (no confusion with `/opt/logs`).
