Got it — I’ll give you the **Tester/VM README** (2nd README) for webcheck: install tools, add your GitHub Pages Helm repo, uninstall old release if exists, install per-URL as separate releases, run manual jobs, and view logs correctly via logs-viewer.


````md
# webcheck (WebDown) Helm Chart — Tester / New VM Guide (Readme-2)

This guide is for a **tester / new VM user** to:
✅ install required tools  
✅ connect to cluster (minikube / EKS / any k8s)  
✅ add your GitHub Pages Helm repo  
✅ install webcheck for **multiple URLs** (each URL = separate release)  
✅ run a manual job for each URL  
✅ watch logs correctly from logs-viewer  
✅ uninstall old releases before installing new ones (no conflicts)

---

## 0) What webcheck does (in simple words)

- It hits a URL (example: `https://dev.agent-botv2.zinger-emplay.net/`) every N minutes.
- If the URL fails after retries, it will:
  1) restart the given Deployment (example: `deployment/botv2` or `deployment/zingerx`)
  2) send an email (if enabled)
  3) write logs into shared logs PVC under a folder like:  
     `/logs/webcheck-botv2/webcheck_YYYY-MM-DD.log`

✅ Best practice: **Each URL you monitor = one Helm release**  
Example releases:
- `webcheck-botv2`
- `webcheck-zingerx`

---

## 1) Prerequisites on VM

### 1.1 Install tools
```bash
sudo apt-get update -y
sudo apt-get install -y curl ca-certificates git

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
````

### 1.2 Ensure kubectl is connected to the cluster

```bash
kubectl get nodes
```

You must see nodes (example: `minikube`).

---

## 2) One-time cluster setup (only if not done already)

### 2.1 Shared logs PVC (ONE TIME per cluster)

This is common for all charts (cpu/disk/memory/webcheck).

```bash
kubectl get pvc -n default | grep self-heal-logs-pvc || echo "NOT FOUND"
```

If NOT FOUND, apply it from your repo (ask maintainer for file) or clone and apply:

```bash
git clone https://github.com/<GITHUB_USERNAME>/<REPO_NAME>.git
cd <REPO_NAME>

kubectl apply -f shared-logs-pvc.yaml
kubectl get pvc -n default | grep self-heal-logs-pvc
```

### 2.2 logs-viewer (ONE TIME per cluster)

```bash
kubectl get deploy -n default logs-viewer >/dev/null 2>&1 && echo "logs-viewer exists" || echo "logs-viewer NOT found"
```

If NOT found:

```bash
kubectl apply -f logs-viewer.yaml
kubectl get pods -n default -l app=logs-viewer
```

---

## 3) Add Helm repo (GitHub Pages)

```bash
helm repo remove self-heal 2>/dev/null || true
helm repo add self-heal https://<GITHUB_USERNAME>.github.io/<REPO_NAME>
helm repo update

helm search repo self-heal | grep webcheck
```

You should see:

* `self-heal/webcheck`

---

## 4) IMPORTANT: uninstall any old webcheck releases (avoid conflicts)

If you already have a `webcheck` release installed, remove it first.
This avoids errors like:
`Service test-webapp-service exists and cannot be imported...`

```bash
helm list -n default | grep webcheck || echo "No webcheck releases installed"
```

To uninstall old releases (examples):

```bash
helm uninstall webcheck -n default 2>/dev/null || true
helm uninstall webcheck-botv2 -n default 2>/dev/null || true
helm uninstall webcheck-zingerx -n default 2>/dev/null || true
```

If you previously enabled the test webapp and service remains, delete them:

```bash
kubectl delete svc test-webapp-service -n default 2>/dev/null || true
kubectl delete deploy test-webapp -n default 2>/dev/null || true
```

---

## 5) Install webcheck for URL-1 (BotV2) — separate release

> Each URL needs its own release name and its own LOG_DIR folder.

```bash
helm upgrade --install webcheck-botv2 self-heal/webcheck -n default \
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

## 6) Install webcheck for URL-2 (ZingerX) — separate release

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

✅ Now both will run in parallel (each has its own CronJob and log folder).

---

## 7) Run manual test job for each URL (do not wait for cron)

### 7.1 Manual job: BotV2

```bash
JOB="webcheck-botv2-manual-$(date +%Y%m%d-%H%M%S)"
kubectl create job --from=cronjob/webcheck-botv2-webcheck-cron "$JOB" -n default

POD=$(kubectl get pods -n default -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n default -f "$POD"
```

### 7.2 Manual job: ZingerX

```bash
JOB="webcheck-zingerx-manual-$(date +%Y%m%d-%H%M%S)"
kubectl create job --from=cronjob/webcheck-zingerx-webcheck-cron "$JOB" -n default

POD=$(kubectl get pods -n default -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n default -f "$POD"
```

---

## 8) Watch logs correctly in logs-viewer (FIXED)

Enter logs-viewer:

```bash
kubectl exec -it -n default deploy/logs-viewer -- sh
```

List folders:

```sh
ls -lh /logs | grep webcheck
# expected:
# webcheck-botv2
# webcheck-zingerx
```

Tail BotV2 log:

```sh
tail -f /logs/webcheck-botv2/webcheck_$(date +%Y-%m-%d).log
```

Tail ZingerX log:

```sh
tail -f /logs/webcheck-zingerx/webcheck_$(date +%Y-%m-%d).log
```

✅ IMPORTANT:

* Do NOT do: `tail -f /logs/webcheck-botv2` (it is a directory)
* Always tail the file inside the folder.

Exit:

```sh
exit
```

---

## 9) Confirm restart happened (only when URL fails)

If URL fails, webcheck runs:

```bash
kubectl rollout restart deployment <WEB_DEPLOYMENT_NAME> -n <WEB_DEPLOYMENT_NAMESPACE>
```

Check rollout:

```bash
kubectl rollout status deployment botv2 -n default
kubectl rollout status deployment zingerx -n default
```

---

## 10) Cleanup / Remove webchecks (optional)

```bash
helm uninstall webcheck-botv2 -n default
helm uninstall webcheck-zingerx -n default
```

(Optional) remove test webapp if you enabled it:

```bash
kubectl delete svc test-webapp-service -n default 2>/dev/null || true
kubectl delete deploy test-webapp -n default 2>/dev/null || true
```

Done ✅

```

If you want, paste your **final current webcheck chart folder structure** (just `ls charts/webcheck`) and I’ll adjust any paths/names exactly to match your repo (so tester won’t hit name mismatch).
```
