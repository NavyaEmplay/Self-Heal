
* **README-1 (Maintainer)** = *create repo + create files/folders + create chart + local test + package + push + GitHub Pages publish + verify URL*
* **README-2 (Tester/New VM)** = *install tools + start cluster + enable metrics + add repo + install chart + run manual job + view logs in one place*


---

# ✅ README-1.md (Maintainer: Create Repo → Build Chart → Publish Helm Repo)

````md
# Self-Heal Helm Repo (Maintainer Guide)
This guide is for **you (the maintainer)** to create the GitHub repo from scratch, build the Helm chart, test it locally, and publish it as a Helm repo using **GitHub Pages**.

---

## 0) What you will build
✅ A Helm chart `cpu-usage` that:
- runs as a **CronJob** (default schedule every 5 minutes)
- checks node CPU using `kubectl top nodes`
- stores logs in a **shared PVC** (`self-heal-logs-pvc`)
- optionally sends email (SMTP) if CPU crosses threshold
- logs are viewable from a **logs-viewer pod** (single place for all logs)

✅ A public Helm repository published at:
`https://<GITHUB_USERNAME>.github.io/<REPO_NAME>`

Example (yours):
`https://NavyaEmplay.github.io/Self-Heal`

---

## 1) Prerequisites (Maintainer machine – Ubuntu)
### 1.1 Install basic tools
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

### 1.4 Install Docker + Minikube (for local testing)

```bash
sudo apt-get install -y docker.io
sudo usermod -aG docker $USER
newgrp docker

curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube
minikube version
```

---

## 2) Create GitHub Repo (FIRST TIME)

### 2.1 Create repo from GitHub UI

1. Go to GitHub → **New repository**
2. Name it exactly (example): `Self-Heal`
3. Set **Public**
4. Create repository (you can keep it empty)

### 2.2 Clone repo to your machine

```bash
cd ~
git clone https://github.com/<GITHUB_USERNAME>/<REPO_NAME>.git
cd <REPO_NAME>
```

Example:

```bash
git clone https://github.com/NavyaEmplay/Self-Heal.git
cd Self-Heal
```

---

## 3) Create folders and files (FULL project structure)

### 3.1 Create folders

```bash
mkdir -p charts/cpu-usage/templates charts/cpu-usage/scripts
mkdir -p docs helm-repo
```

Your structure becomes:

```
Self-Heal/
├─ charts/
│  └─ cpu-usage/
│     ├─ Chart.yaml
│     ├─ values.yaml
│     ├─ templates/
│     │  └─ all.yaml
│     └─ scripts/
│        ├─ checkcpu.sh
│        └─ utils.sh
├─ docs/
├─ helm-repo/
├─ shared-logs-pvc.yaml
└─ logs-viewer.yaml
```

---

## 4) Add ALL files (copy-paste these exactly)

### 4.1 charts/cpu-usage/Chart.yaml

```yaml
apiVersion: v2
name: cpu-usage
description: Self-heal CPU monitoring CronJob (kubectl top nodes)
type: application
version: 0.1.0
appVersion: "1.0.0"
```

### 4.2 charts/cpu-usage/values.yaml

```yaml
schedule: "*/5 * * * *"

image:
  repository: python
  tag: 3.11-slim

config:
  RETRY_COUNT: "3"
  RETRY_INTERVAL: "10"
  COOLDOWN_PERIOD: "7200"
  CPU_THRESHOLD: "60"
  LOG_DIR: "/opt/logs"
  EMAIL_ENABLED: "true"
  EMAIL_SUBJECT_PREFIX: "[Self-Heal][CPU]"
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

# ✅ IMPORTANT: shared logs pvc should be created ONE TIME manually (recommended)
sharedLogsPVC:
  name: "self-heal-logs-pvc"
```

### 4.3 charts/cpu-usage/scripts/utils.sh

```bash
#!/bin/bash

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" | tee -a "$LOG_DIR/cpucheck_$(date '+%Y-%m-%d').log"
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
    SUBJECT="$EMAIL_SUBJECT_PREFIX High CPU Alert on $node"
    BODY="ALERT: Node $node CPU=$usage% (Threshold=$CPU_THRESHOLD%)"

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

### 4.4 charts/cpu-usage/scripts/checkcpu.sh

```bash
#!/bin/bash
source /opt/config/config.env
source /opt/utils/utils.sh

find "$LOG_DIR" -type f -name "cpucheck_*.log" -mtime +7 -delete || true

check_cpu() {
  log "DEBUG" "Checking CPU usage across all nodes..."
  alert=0
  max_usage=0
  max_node=""
  total_count=0

  while read -r node cpu mem; do
    usage=${cpu%\%}
    total_count=$((total_count+1))

    if [ "$usage" -ge "$CPU_THRESHOLD" ]; then
      log "WARNING" "Node $node is above threshold: ${usage}%"
      alert=1
    else
      log "INFO" "Node $node is healthy: ${usage}%"
    fi

    if [ "$usage" -gt "$max_usage" ]; then
      max_usage=$usage
      max_node=$node
    fi
  done < <(kubectl top nodes --no-headers | awk '{print $1, $3, $5}')

  echo "$max_node" > /opt/state/max_node
  echo "$max_usage" > /opt/state/max_usage

  if [ $alert -eq 0 ]; then
    log "INFO" "All $total_count nodes healthy. Highest usage=$max_usage% on $max_node"
  else
    log "ERROR" "High CPU detected. Worst=$max_usage% on $max_node"
  fi
  return $alert
}

if retry_with_config check_cpu $RETRY_COUNT $RETRY_INTERVAL; then
  exit 0
else
  if can_alert $COOLDOWN_PERIOD; then
    NODE=$(cat /opt/state/max_node)
    USAGE=$(cat /opt/state/max_usage)
    send_email "$NODE" "$USAGE"
    log "INFO" "Email sent (Node=$NODE, Usage=$USAGE%)"
  fi
  exit 0
fi
```

### 4.5 charts/cpu-usage/templates/all.yaml

✅ You asked: “**helpers inside all.yaml itself**” → done below.

```yaml
{{- define "cpu-usage.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "cpu-usage.fullname" . }}-scripts
  namespace: {{ .Release.Namespace }}
data:
  config.env: |
    RETRY_COUNT={{ .Values.config.RETRY_COUNT }}
    RETRY_INTERVAL={{ .Values.config.RETRY_INTERVAL }}
    COOLDOWN_PERIOD={{ .Values.config.COOLDOWN_PERIOD }}
    CPU_THRESHOLD={{ .Values.config.CPU_THRESHOLD }}
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

  checkcpu.sh: |
{{ .Files.Get "scripts/checkcpu.sh" | indent 4 }}

---
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "cpu-usage.fullname" . }}-smtp
  namespace: {{ .Release.Namespace }}
type: Opaque
stringData:
  SMTP_PASSWORD: {{ .Values.secrets.SMTP_PASSWORD | quote }}

---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "cpu-usage.fullname" . }}-state
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
  name: {{ include "cpu-usage.fullname" . }}-sa
  namespace: {{ .Release.Namespace }}

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: {{ include "cpu-usage.fullname" . }}-role
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
  name: {{ include "cpu-usage.fullname" . }}-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: {{ include "cpu-usage.fullname" . }}-role
subjects:
- kind: ServiceAccount
  name: {{ include "cpu-usage.fullname" . }}-sa
  namespace: {{ .Release.Namespace }}

---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: {{ include "cpu-usage.fullname" . }}-cron
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
          serviceAccountName: {{ include "cpu-usage.fullname" . }}-sa
          restartPolicy: OnFailure
          containers:
          - name: cpu-usage
            image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
            command: ["/bin/bash","-c"]
            args:
              - |
                set -e
                apt-get update && apt-get install -y curl ca-certificates && \
                curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
                install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && \
                bash /opt/scripts/checkcpu.sh
            volumeMounts:
            - name: scripts
              subPath: checkcpu.sh
              mountPath: /opt/scripts/checkcpu.sh
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
              name: {{ include "cpu-usage.fullname" . }}-scripts
          - name: state
            persistentVolumeClaim:
              claimName: {{ include "cpu-usage.fullname" . }}-state
          - name: logs
            persistentVolumeClaim:
              claimName: {{ .Values.sharedLogsPVC.name }}
          - name: smtpsecret
            secret:
              secretName: {{ include "cpu-usage.fullname" . }}-smtp
```

### 4.6 shared-logs-pvc.yaml  (ONE TIME per cluster)

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

### 4.7 logs-viewer.yaml (ONE TIME per cluster)

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

---

## 5) Local test (Maintainer)

### 5.1 Start cluster + metrics

```bash
minikube start --driver=docker
minikube addons enable metrics-server
kubectl top nodes
```

### 5.2 Apply ONE TIME objects (shared logs + viewer)

```bash
kubectl apply -f shared-logs-pvc.yaml
kubectl apply -f logs-viewer.yaml
kubectl get pvc -n default | grep self-heal-logs-pvc
kubectl get pods -n default -l app=logs-viewer
```

### 5.3 Lint + install chart locally

```bash
cd charts/cpu-usage
helm lint .

helm uninstall cpu-usage -n default 2>/dev/null || true
helm install cpu-usage . -n default --create-namespace \
  --set-string secrets.SMTP_PASSWORD="YOUR_SMTP_APP_PASSWORD"
```

### 5.4 Manual run test (don’t wait for cron)

```bash
JOB="cpu-usage-manual-$(date +%Y%m%d-%H%M%S)"
kubectl create job --from=cronjob/cpu-usage-cpu-usage-cron "$JOB" -n default
POD=$(kubectl get pods -n default -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n default -f "$POD"
```

### 5.5 Check logs from single place (logs-viewer)

```bash
kubectl exec -it -n default deploy/logs-viewer -- sh
ls -lh /opt/logs
tail -f /opt/logs/cpucheck_$(date +%Y-%m-%d).log
```

---

## 6) Build Helm repo artifacts (tgz + index.yaml)

From repo root:

```bash
cd <REPO_NAME>

mkdir -p helm-repo docs
rm -rf helm-repo/* docs/*

for d in charts/*; do
  [ -d "$d" ] && helm package "$d" -d helm-repo
done

helm repo index helm-repo --url https://<GITHUB_USERNAME>.github.io/<REPO_NAME>

cp -r helm-repo/* docs/
touch docs/.nojekyll

ls -lh docs
```

You must see in `docs/`:

* `index.yaml`
* `cpu-usage-0.1.0.tgz`

---

## 7) Push everything to GitHub

```bash
git add .
git commit -m "cpu-usage chart + publish helm repo"
git push origin main
```

---

## 8) Enable GitHub Pages (Publishing)

GitHub Repo → **Settings → Pages**

* Source: Deploy from branch
* Branch: `main`
* Folder: `/docs`
  Save.

Now your Helm repo URL becomes:
`https://<GITHUB_USERNAME>.github.io/<REPO_NAME>`

Example:
`https://NavyaEmplay.github.io/Self-Heal`

---

## 9) Final verification (Helm repo must work)

From any machine:

```bash
helm repo add self-heal https://<GITHUB_USERNAME>.github.io/<REPO_NAME>
helm repo update
helm search repo self-heal
```

Done ✅

````

