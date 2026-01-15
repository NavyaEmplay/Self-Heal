# ✅ README-2 (Tester/New VM): Install + Run + Verify logs

## 1) Install tools

```bash
sudo apt-get update -y
sudo apt-get install -y git curl ca-certificates
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
```

## 2) One-time: apply shared PVC + logs-viewer

```bash
kubectl apply -f shared-logs-pvc.yaml
kubectl apply -f logs-viewer.yaml
kubectl get pvc -n default | grep self-heal-logs-pvc
kubectl get pods -n default -l app=logs-viewer
```

## 3) Add Helm repo + install chart

```bash
helm repo add self-heal https://NavyaEmplay.github.io/Self-Heal
helm repo update

helm uninstall cpu-precheck -n default 2>/dev/null || true
helm install cpu-precheck self-heal/cpu-precheck -n default --create-namespace \
  --set-string secrets.SMTP_PASSWORD="YOUR_SMTP_APP_PASSWORD"
```

## 4) Manual test

```bash
JOB="cpu-precheck-manual-$(date +%Y%m%d-%H%M%S)"
kubectl create job --from=cronjob/cpu-precheck-cpu-precheck-cron "$JOB" -n default
POD=$(kubectl get pods -n default -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n default -f "$POD"
```

## 5) View logs in one place

```bash
kubectl exec -it -n default deploy/logs-viewer -- sh
ls -lh /opt/logs
tail -f /opt/logs/precheck_$(date +%Y-%m-%d).log
```

```

---

If you want, I can also give you a **single `publish.sh` script** (one command to package + index + copy to docs + git push) that you run from repo root.
::contentReference[oaicite:0]{index=0}
```
