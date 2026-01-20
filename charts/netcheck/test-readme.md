
---

## ✅ README-2 (Tester/New VM) — `netcheck` (with Email)  
Save as: `charts/netcheck/test-Readme.md`

```md
# netcheck Helm Chart (Tester/New User Guide) — With Email

This guide helps you:
✅ add Helm repo  
✅ install netcheck  
✅ run manual test job  
✅ view logs via logs-viewer  
✅ confirm email behavior

---

## 1) Prerequisites
kubectl must work:
```bash
kubectl get nodes
````

---

## 2) Install tools

```bash
sudo apt-get update -y
sudo apt-get install -y git curl ca-certificates

curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
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

* self-heal/netcheck

---

## 4) Install netcheck (with SMTP app password)

```bash
helm uninstall netcheck -n default 2>/dev/null || true

helm install netcheck self-heal/netcheck -n default --create-namespace \
  --set-string secrets.SMTP_PASSWORD="YOUR_SMTP_APP_PASSWORD"
```

Verify:

```bash
kubectl get cronjob -n default | grep netcheck
```

---

## 5) Manual test run (run now)

```bash
JOB="netcheck-manual-$(date +%Y%m%d-%H%M%S)"
kubectl create job --from=cronjob/netcheck-netcheck-cron "$JOB" -n default

POD=$(kubectl get pods -n default -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n default -f "$POD"
```

Expected sample output:

* Network connectivity healthy (HTTP succeeded)
  OR
* Network connectivity issue detected (failed)

---

## 6) View logs via logs-viewer

```bash
kubectl exec -it -n default deploy/logs-viewer -- sh
ls -lh /opt/logs
tail -f /opt/logs/netcheck_$(date +%Y-%m-%d).log
```

---

## 7) How to force-fail test (to confirm email)

You can install with a bad URL so it fails:

```bash
helm upgrade --install netcheck self-heal/netcheck -n default \
  --set-string secrets.SMTP_PASSWORD="YOUR_SMTP_APP_PASSWORD" \
  --set-string config.NETWORK_TARGET_URL="https://invalid.invalidtestdomain"
```

Run manual job again:

```bash
JOB="netcheck-manual-$(date +%Y%m%d-%H%M%S)"
kubectl create job --from=cronjob/netcheck-netcheck-cron "$JOB" -n default
POD=$(kubectl get pods -n default -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n default -f "$POD"
```

After test, restore URL:

```bash
helm upgrade --install netcheck self-heal/netcheck -n default \
  --set-string secrets.SMTP_PASSWORD="YOUR_SMTP_APP_PASSWORD" \
  --set-string config.NETWORK_TARGET_URL="https://www.google.com"
```

---

## 8) Cleanup (optional)

```bash
helm uninstall netcheck -n default
```

Done ✅

```
```
