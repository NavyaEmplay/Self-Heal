
````md
# nginx-check Helm Chart (Self-Heal Nginx Ingress Pod Readiness + Email) — Maintainer Guide

This chart deploys a Kubernetes **CronJob** that checks whether **nginx-ingress controller pods** are Ready.

✅ Checks: `kubectl get pods -l app.kubernetes.io/name=nginx-ingress`  
✅ If any pod is not Ready/Running → retries → cooldown → sends email  
✅ Logs saved to shared logs PVC: `self-heal-logs-pvc`  
✅ State stored in a small PVC: `nginxcheck-state-pvc` (cooldown + bad_pods)  

---

## 0) What are we actually testing?

This script checks the **control-plane health of the nginx ingress controller pods**, NOT the HTTP routing.

### ✅ We confirm
- nginx ingress controller pods exist
- pods are **Running**
- pods are **Ready (1/1)** with restart count visible
- if they go unhealthy → retries and alerts

### ❌ We do NOT confirm
- your ingress rules are correct
- your backend service is reachable
- HTTP 200 / TLS / DNS is working

(If you want HTTP-level check, we can make another script later using curl to your Ingress URL.)

---

## 1) One-time cluster setup (shared logs PVC + logs-viewer)

From repo root:

```bash
cd ~/Emplay/self-heal-helm-repo

kubectl apply -f shared-logs-pvc.yaml
kubectl apply -f logs-viewer.yaml

kubectl get pvc -n default | grep self-heal-logs-pvc
kubectl get pods -n default -l app=logs-viewer
````

---

## 2) Install Nginx Ingress Controller (needed for testing)

You said you have nothing right now, so follow this section.

### Option A (Minikube - easiest)

```bash
minikube addons enable ingress
kubectl get pods -n ingress-nginx
```

Expected: pods like `ingress-nginx-controller-...` should be Running.

### Option B (Any cluster using Helm)

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace

kubectl get pods -n ingress-nginx
```

---

## 3) Create a sample app + service + ingress (for realistic test)

This creates a small echo app and routes traffic via Ingress.

```bash
kubectl apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-echo
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demo-echo
  template:
    metadata:
      labels:
        app: demo-echo
    spec:
      containers:
      - name: echo
        image: hashicorp/http-echo:1.0
        args:
          - "-text=hello-from-nginx-ingress"
        ports:
          - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: demo-echo-svc
  namespace: default
spec:
  selector:
    app: demo-echo
  ports:
    - port: 80
      targetPort: 5678
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo-echo-ingress
  namespace: default
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
  - host: demo.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: demo-echo-svc
            port:
              number: 80
YAML
```

Verify:

```bash
kubectl get deploy,svc,ingress -n default
```

### Test HTTP (Minikube)

```bash
minikube tunnel
curl -H "Host: demo.local" http://127.0.0.1/
```

Expected output: `hello-from-nginx-ingress`

---

## 4) Create chart structure

```bash
cd ~/Emplay/self-heal-helm-repo
mkdir -p charts/nginx-check/templates charts/nginx-check/scripts
```

Expected:

```
charts/nginx-check/
├─ Chart.yaml
├─ values.yaml
├─ templates/all.yaml
└─ scripts/
   ├─ utils.sh
   └─ checknginx.sh
```

---

## 5) Add chart files (copy/paste)

### 5.1 charts/nginx-check/Chart.yaml

```yaml
apiVersion: v2
name: nginx-check
description: Self-heal nginx ingress controller readiness checker with retries, cooldown, email alerts, shared logs
type: application
version: 0.1.0
appVersion: "1.0.0"
```

---

### 5.2 charts/nginx-check/values.yaml

```yaml
schedule: "*/5 * * * *"

image:
  repository: python
  tag: 3.11-slim
  pullPolicy: IfNotPresent

config:
  RETRY_COUNT: "3"
  RETRY_INTERVAL: "10"
  COOLDOWN_PERIOD: "7200"
  LOG_DIR: "/opt/logs"

  # Labels to find nginx ingress controller pods
  # If you installed via minikube addon or ingress-nginx helm, namespace is usually ingress-nginx.
  NGINX_NAMESPACE: "ingress-nginx"
  NGINX_LABEL_SELECTOR: "app.kubernetes.io/name=ingress-nginx"

  EMAIL_ENABLED: "true"
  EMAIL_SUBJECT_PREFIX: "[Self-Heal][Nginx]"
  EMAIL_FROM: "qa_emplay@emplay.net"
  EMAIL_TO: "nandhini.s@emplay.net,navya.sri@emplay.net"
  SMTP_HOST: "smtp.gmail.com"
  SMTP_PORT: "587"
  SMTP_USERNAME: "qa_emplay@emplay.net"

secrets:
  SMTP_PASSWORD: ""   # pass during helm install

persistence:
  state:
    size: 5Mi

sharedLogsPVC:
  name: "self-heal-logs-pvc"
```

✅ Why I changed the selector:

* Your script uses `app.kubernetes.io/name=nginx-ingress` in `default` namespace.
* In real clusters, ingress-nginx controller runs in **ingress-nginx namespace** and label is commonly:

  * `app.kubernetes.io/name=ingress-nginx`
    So I made it configurable and more correct for real deployments.

---

### 5.3 charts/nginx-check/scripts/utils.sh

```bash
#!/bin/bash
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" | tee -a "$LOG_DIR/nginxcheck_$(date '+%Y-%m-%d').log"
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
  local details="$1"
  SMTP_PASSWORD="$(cat "$SMTP_PASSWORD_FILE" 2>/dev/null || true)"

  if [ "$EMAIL_ENABLED" = "true" ]; then
    SUBJECT="$EMAIL_SUBJECT_PREFIX Nginx Pod Alert"
    BODY="ALERT: Some nginx ingress pods are not Ready.\n\n$details\n\nPlease investigate and restart manually if needed."

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

### 5.4 charts/nginx-check/scripts/checknginx.sh

```bash
#!/bin/bash
set -euo pipefail

source /opt/config/config.env
source /opt/utils/utils.sh

mkdir -p "$LOG_DIR" /opt/state
find "$LOG_DIR" -type f -name "nginxcheck_*.log" -mtime +7 -delete || true

check_nginx_pods() {
  log "DEBUG" "Checking nginx ingress controller pod readiness..."
  alert=0
  bad_pods=()

  ns="${NGINX_NAMESPACE:-default}"
  sel="${NGINX_LABEL_SELECTOR:-app.kubernetes.io/name=ingress-nginx}"

  # If no pods match selector, treat as failure (because controller missing)
  pods_count="$(kubectl get pods -n "$ns" -l "$sel" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${pods_count:-0}" = "0" ]; then
    log "ERROR" "No nginx ingress pods found (ns=$ns selector=$sel). Is ingress controller installed?"
    echo "No nginx ingress pods found (ns=$ns selector=$sel)" > /opt/state/bad_pods
    return 1
  fi

  while read -r pod ready status restarts; do
    if [[ "$ready" != "1/1" || "$status" != "Running" ]]; then
      log "ERROR" "Pod $pod not Ready (Ready=$ready, Status=$status, Restarts=$restarts)"
      alert=1
      bad_pods+=("$pod Ready=$ready Status=$status Restarts=$restarts")
    else
      log "INFO" "Pod $pod healthy (Ready=$ready, Status=$status, Restarts=$restarts)"
    fi
  done < <(kubectl get pods -n "$ns" -l "$sel" --no-headers | awk '{print $1, $2, $3, $4}')

  echo "${bad_pods[@]}" > /opt/state/bad_pods

  if [ $alert -eq 0 ]; then
    log "INFO" "All nginx ingress pods are Ready"
  else
    log "ERROR" "Some nginx ingress pods are not Ready"
  fi

  return $alert
}

if retry_with_config check_nginx_pods "$RETRY_COUNT" "$RETRY_INTERVAL"; then
  exit 0
else
  if can_alert "$COOLDOWN_PERIOD"; then
    PODS=$(cat /opt/state/bad_pods 2>/dev/null || echo "unknown")
    send_email "$PODS"
    log "INFO" "Email sent (Pods=$PODS)"
  fi
  exit 0
fi
```

---

### 5.5 charts/nginx-check/templates/all.yaml

```yaml
{{- define "nginxcheck.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "nginxcheck.fullname" . }}-scripts
  namespace: {{ .Release.Namespace }}
data:
  config.env: |
    RETRY_COUNT={{ .Values.config.RETRY_COUNT }}
    RETRY_INTERVAL={{ .Values.config.RETRY_INTERVAL }}
    COOLDOWN_PERIOD={{ .Values.config.COOLDOWN_PERIOD }}
    LOG_DIR={{ .Values.config.LOG_DIR }}

    NGINX_NAMESPACE={{ .Values.config.NGINX_NAMESPACE }}
    NGINX_LABEL_SELECTOR={{ .Values.config.NGINX_LABEL_SELECTOR | quote }}

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

  checknginx.sh: |
{{ .Files.Get "scripts/checknginx.sh" | indent 4 }}

---
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "nginxcheck.fullname" . }}-smtp
  namespace: {{ .Release.Namespace }}
type: Opaque
stringData:
  SMTP_PASSWORD: {{ .Values.secrets.SMTP_PASSWORD | quote }}

---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "nginxcheck.fullname" . }}-state
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
  name: {{ include "nginxcheck.fullname" . }}-sa
  namespace: {{ .Release.Namespace }}

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: {{ include "nginxcheck.fullname" . }}-role
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get","list"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: {{ include "nginxcheck.fullname" . }}-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: {{ include "nginxcheck.fullname" . }}-role
subjects:
- kind: ServiceAccount
  name: {{ include "nginxcheck.fullname" . }}-sa
  namespace: {{ .Release.Namespace }}

---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: {{ include "nginxcheck.fullname" . }}-cron
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
          serviceAccountName: {{ include "nginxcheck.fullname" . }}-sa
          restartPolicy: OnFailure
          containers:
          - name: nginx-check
            image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
            imagePullPolicy: {{ .Values.image.pullPolicy }}
            command: ["/bin/bash","-c"]
            args:
              - |
                set -e
                apt-get update && \
                apt-get install -y curl gnupg apt-transport-https ca-certificates && \
                curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
                install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && \
                bash /opt/scripts/checknginx.sh
            volumeMounts:
            - name: scripts
              subPath: checknginx.sh
              mountPath: /opt/scripts/checknginx.sh
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
              name: {{ include "nginxcheck.fullname" . }}-scripts
          - name: state
            persistentVolumeClaim:
              claimName: {{ include "nginxcheck.fullname" . }}-state
          - name: logs
            persistentVolumeClaim:
              claimName: {{ .Values.sharedLogsPVC.name }}
          - name: smtpsecret
            secret:
              secretName: {{ include "nginxcheck.fullname" . }}-smtp
```

---

## 6) Local test (Maintainer)

### 6.1 Lint + Install

```bash
cd ~/Emplay/self-heal-helm-repo/charts/nginx-check
helm lint .

helm uninstall nginx-check -n default 2>/dev/null || true

helm install nginx-check . -n default --create-namespace \
  --set-string secrets.SMTP_PASSWORD="YOUR_SMTP_APP_PASSWORD"
```

Verify:

```bash
kubectl get cronjob -n default | grep nginx-check
kubectl get pvc -n default | grep nginx-check
```

### 6.2 Manual run test (don’t wait for cron)

```bash
JOB="nginx-check-manual-$(date +%Y%m%d-%H%M%S)"
kubectl create job --from=cronjob/nginx-check-nginx-check-cron "$JOB" -n default

POD=$(kubectl get pods -n default -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n default -f "$POD"
```

### 6.3 View logs in one place (logs-viewer)

```bash
kubectl exec -it -n default deploy/logs-viewer -- sh
ls -lh /opt/logs
tail -f /opt/logs/nginxcheck_$(date '+%Y-%m-%d').log
```

---

## 7) Publish ALL charts to GitHub Pages (docs/) — your safe steps

```bash
cd ~/Emplay/self-heal-helm-repo

rm -rf helm-repo/*
for d in charts/*; do
  [ -d "$d" ] && helm package "$d" -d helm-repo
done

helm repo index helm-repo --url https://NavyaEmplay.github.io/Self-Heal

rm -rf docs/*
cp -r helm-repo/* docs/
touch docs/.nojekyll

git add docs helm-repo charts/nginx-check
git commit -m "Add nginx-check chart + publish helm repo"
git push
```

Done ✅

````
