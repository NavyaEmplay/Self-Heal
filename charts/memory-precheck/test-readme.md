
---

## ✅ README-2 (Tester/New VM) — `memory-precheck` (with Email)  
Save as: `charts/memory-precheck/test-Readme.md`

```md
# memory-precheck Helm Chart (Tester/New User Guide) — With Email

This guide helps you:
✅ add Helm repo  
✅ install memory-precheck  
✅ run manual test job  
✅ view logs via logs-viewer  
✅ confirm email behavior  

---

## 1) Prerequisites
kubectl must work:
```bash
kubectl get nodes
````

Metrics must work:

```bash
kubectl top nodes
```

If `kubectl top nodes` fails:
Minikube:

```bash
minikube addons enable metrics-server
```

Wait 1–2 mins:

```bash
kubectl top nodes
```

---

## 2) Install tools

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

## 3) Add Helm repo

```bash
helm repo remove self-heal 2>/dev/null || true
helm repo add self-heal https://NavyaEmplay.github.io/Self-Heal
helm repo update
helm search repo self-heal
```

You should see:

* self-heal/memory-precheck

---

## 4) Install memory-precheck (with SMTP app password)

```bash
helm uninstall memory-precheck -n default 2>/dev/null || true

helm install memory-precheck self-heal/memory-precheck -n default --create-namespace \
  --set-string secrets.SMTP_PASSWORD="YOUR_SMTP_APP_PASSWORD"
```

Verify:

```bash
kubectl get cronjob -n default | grep memory-precheck
kubectl top nodes
```

---

## 5) Manual test run (run now)

```bash
JOB="memory-precheck-manual-$(date +%Y%m%d-%H%M%S)"
kubectl create job --from=cronjob/memory-precheck-memory-precheck-cron "$JOB" -n default

POD=$(kubectl get pods -n default -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n default -f "$POD"
```

Expected log examples:

* Node X memory healthy
* OR High Memory detected (precheck)

---

## 6) View logs via logs-viewer

```bash
kubectl exec -it -n default deploy/logs-viewer -- sh
ls -lh /opt/logs
tail -f /opt/logs/memoryprecheck_$(date +%Y-%m-%d).log
```

---

## 7) How to confirm email is working (quick test)

Email triggers only when:

* Memory stays above threshold after retries AND
* Cooldown allows alert

To force test quickly (optional):
Install with very low threshold:

```bash
helm upgrade --install memory-precheck self-heal/memory-precheck -n default \
  --set-string secrets.SMTP_PASSWORD="YOUR_SMTP_APP_PASSWORD" \
  --set-string config.MEMORY_THRESHOLD="1"
```

Run manual job again:

```bash
JOB="memory-precheck-manual-$(date +%Y%m%d-%H%M%S)"
kubectl create job --from=cronjob/memory-precheck-memory-precheck-cron "$JOB" -n default
POD=$(kubectl get pods -n default -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n default -f "$POD"
```

After test, restore threshold:

```bash
helm upgrade --install memory-precheck self-heal/memory-precheck -n default \
  --set-string secrets.SMTP_PASSWORD="YOUR_SMTP_APP_PASSWORD" \
  --set-string config.MEMORY_THRESHOLD="60"
```

---

## 8) Cleanup (optional)

```bash
helm uninstall memory-precheck -n default
```

Done ✅

```

---

If you want the manual-job command to use a **short cronjob name** (example: `memory-precheck-cron` instead of `memory-precheck-memory-precheck-cron`), I can adjust the Helm fullname template to match your preferred naming style across all charts.
```
