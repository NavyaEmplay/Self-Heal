
Below is the **entire setup from scratch**.

---

## 1) New VM prerequisites + installs (Ubuntu)

```bash
sudo apt-get update -y
sudo apt-get install -y curl wget git ca-certificates apt-transport-https

# Docker
sudo apt-get install -y docker.io
sudo usermod -aG docker $USER
newgrp docker
docker --version

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm -f kubectl
kubectl version --client

# Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version

# Minikube
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube
rm -f minikube-linux-amd64
minikube version
```

---

## 2) Start Minikube + enable metrics (required for `kubectl top nodes`)

```bash
minikube start --driver=docker
kubectl get nodes -o wide

# Metrics Server (needed for kubectl top)
minikube addons enable metrics-server

# Wait a bit then verify:
kubectl get pods -n kube-system | grep metrics
kubectl top nodes
```

If `kubectl top nodes` works, your script will work.

---

## 3) Create repo structure + Helm chart

```bash
mkdir -p ~/self-heal-helm-repo
cd ~/self-heal-helm-repo

mkdir -p charts docs helm-repo
cd charts

helm create cpu-usage
```

Remove default templates (we’ll use only `all.yaml`):

```bash
rm -rf cpu-usage/templates/*
rm -rf cpu-usage/charts
mkdir -p cpu-usage/templates
mkdir -p cpu-usage/scripts
```

---

## 4) Add scripts

### 4.1 `scripts/checkcpu.sh`

```bash
nano cpu-usage/scripts/checkcpu.sh
```

Paste:

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

```bash
chmod +x cpu-usage/scripts/checkcpu.sh
```

### 4.2 `scripts/utils.sh`

```bash
nano cpu-usage/scripts/utils.sh
```

Paste:

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

```bash
chmod +x cpu-usage/scripts/utils.sh
```

---

## 5) Update Chart.yaml (simple)

```bash
nano cpu-usage/Chart.yaml
```

Use:

```yaml
apiVersion: v2
name: cpu-usage
description: Self-heal CPU monitoring CronJob (kubectl top nodes)
type: application
version: 0.1.0
appVersion: "1.0.0"
```

---

## 6) values.yaml (NEW: chart creates logs PVC too, so no manual PVC needed)

```bash
nano cpu-usage/values.yaml
```

Paste:

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

# Shared logs PVC (created by this chart)
sharedLogsPVC:
  enabled: true
  name: "self-heal-logs-pvc"
  size: 100Mi
  storageClassName: "standard"
```

---

## 7) ✅ Single template file: `templates/all.yaml` (helpers inside the same file)

```bash
nano cpu-usage/templates/all.yaml
```

Paste this **entire file**:

```yaml
{{/*
Helpers inside all.yaml (no _helpers.tpl needed)
*/}}

{{- define "cpu-usage.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cpu-usage.fullname" -}}
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

✅ Now you have **only one template file** and it contains the helpers too.

---

## 8) Lint + Install (test)

```bash
cd ~/self-heal-helm-repo/charts/cpu-usage
helm lint .

# install to default namespace
helm install cpu-usage . -n default --create-namespace \
  --set-string secrets.SMTP_PASSWORD="YOUR_APP_PASSWORD"
```

Check resources:

```bash
kubectl get cronjob -n default
kubectl get pvc -n default | grep -E "self-heal-logs-pvc|cpu-usage"
kubectl get pods -n default
```

---

## 9) Manual test run + logs in terminal

Create job from cronjob:

```bash
kubectl create job --from=cronjob/cpu-usage-cpu-usage-cron cpu-usage-manual -n default
```

Watch pod:

```bash
kubectl get pods -n default -l job-name=cpu-usage-manual -w
```

Show logs:

```bash
kubectl logs -n default -l job-name=cpu-usage-manual --all-containers=true
```

If it completed already, logs still work:

```bash
kubectl logs -n default job/cpu-usage-manual
```

---

## 10) Optional: Publish Helm repo to GitHub Pages (clean way)

From repo root:

```bash
cd ~/self-heal-helm-repo
rm -rf helm-repo/* docs/*
helm package charts/cpu-usage -d helm-repo
helm repo index helm-repo --url https://<YOUR_GITHUB_USERNAME>.github.io/self-heal-helm-repo
cp -r helm-repo/* docs/
```

Push to GitHub:

```bash
git init
git add .
git commit -m "cpu-usage chart + helm repo"
git branch -M main
git remote add origin https://github.com/<YOUR_GITHUB_USERNAME>/self-heal-helm-repo.git
git push -u origin main
```

Enable Pages:

* GitHub repo → **Settings → Pages**
* Source: **Deploy from a branch**
* Branch: `main`, folder: `/docs`

Test install from GitHub:

```bash
helm repo add selfheal https://<YOUR_GITHUB_USERNAME>.github.io/self-heal-helm-repo
helm repo update
helm search repo selfheal
helm install cpu-usage selfheal/cpu-usage -n default --create-namespace \
  --set-string secrets.SMTP_PASSWORD="YOUR_APP_PASSWORD"
```

---

### Small note (why you saw “Metrics API not available”)

That happens **only** when metrics-server is missing. After:

```bash
minikube addons enable metrics-server
kubectl top nodes
```

your script will start showing real node CPU values.

---

If you want, paste your `<YOUR_GITHUB_USERNAME>` and I’ll rewrite the publish commands with your exact final URL filled in (no placeholders).
