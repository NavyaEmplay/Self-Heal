
---

## ✅ README-2 (Tester/New VM) — `memory-alert` (with Email)  
Save as: `charts/memory-alert/test-Readme.md`

```md
# memory-alert Helm Chart (Tester/New User Guide) — With Email

This guide helps you:
✅ add Helm repo  
✅ install memory-alert  
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

* self-heal/memory-alert

---

## 4) Install memory-alert (with SMTP app password)

```bash
helm uninstall memory-alert -n default 2>/dev/null || true

helm install memory-alert self-heal/memory-alert -n default --create-namespace \
  --set-string secrets.SMTP_PASSWORD="YOUR_SMTP_APP_PASSWORD"
```

Verify:

```bash
kubectl get cronjob -n default | grep memory-alert
kubectl top nodes
```

---

## 5) Manual test run (run now, don’t wait for schedule)

```bash
JOB="memory-alert-manual-$(date +%Y%m%d-%H%M%S)"
kubectl create job --from=cronjob/memory-alert-memory-alert-cron "$JOB" -n default

POD=$(kubectl get pods -n default -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n default -f "$POD"
```

---

## 6) View logs via logs-viewer

```bash
kubectl exec -it -n default deploy/logs-viewer -- sh
ls -lh /opt/logs
tail -f /opt/logs/memoryalert_$(date +%Y-%m-%d).log
```

---

## 7) How to confirm email is working

Email triggers only when:

* Memory stays above threshold after retries AND
* Cooldown window allows alert

To force test quickly (optional):

* Temporarily set threshold low (example 1%) when installing:

```bash
helm upgrade --install memory-alert self-heal/memory-alert -n default \
  --set-string secrets.SMTP_PASSWORD="YOUR_SMTP_APP_PASSWORD" \
  --set-string config.MEMORY_THRESHOLD="1"
```

Then run manual job again:

```bash
JOB="memory-alert-manual-$(date +%Y%m%d-%H%M%S)"
kubectl create job --from=cronjob/memory-alert-memory-alert-cron "$JOB" -n default
POD=$(kubectl get pods -n default -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n default -f "$POD"
```

You should see:

* `Email sent (Node=..., Usage=...%)`

After testing, restore real threshold:

```bash
helm upgrade --install memory-alert self-heal/memory-alert -n default \
  --set-string secrets.SMTP_PASSWORD="YOUR_SMTP_APP_PASSWORD" \
  --set-string config.MEMORY_THRESHOLD="65"
```

---

## 8) Cleanup (optional)

```bash
helm uninstall memory-alert -n default
```

Done ✅

```

---

If you want, I can also align the **release name + cronjob name** exactly like your cpu/disk naming convention (so the manual job command always matches one predictable cronjob name).
```
