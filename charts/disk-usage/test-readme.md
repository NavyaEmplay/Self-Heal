
````md
# disk-usage Helm Chart — Tester / New VM Guide (Install + Test)

This guide is for a new person/new VM to:
✅ install tools  
✅ connect to Kubernetes cluster (Minikube/EKS etc.)  
✅ add the Helm repo from GitHub Pages  
✅ install **disk-usage** chart  
✅ trigger a manual run (don’t wait for cron)  
✅ view logs via logs-viewer  
✅ (optional) publish charts to GitHub Pages using safe steps (if you are maintaining repo)

---

## 1) Prerequisites
- Ubuntu VM
- Internet access
- Kubernetes cluster available (Minikube OR EKS/AKS)
- kubectl configured and working

Check:
```bash
kubectl get nodes
````

---

## 2) Install tools (Helm + kubectl + git)

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

## 3) If using Minikube (optional)

```bash
sudo apt-get install -y docker.io
sudo usermod -aG docker $USER
newgrp docker

curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube

minikube start --driver=docker
kubectl get nodes
```

---

## 4) One-time setup in cluster (shared logs PVC + logs-viewer)

### 4.1 Clone repo (to apply PVC and logs-viewer yaml)

```bash
mkdir -p ~/test-self-heal
cd ~/test-self-heal
git clone https://github.com/<GITHUB_USERNAME>/<REPO_NAME>.git
cd <REPO_NAME>
ls
```

### 4.2 Apply shared logs PVC (ONE TIME per cluster)

```bash
kubectl apply -f shared-logs-pvc.yaml
kubectl get pvc -n default | grep self-heal-logs-pvc
```


### 4.3 Apply logs-viewer (ONE TIME per cluster)

```bash
kubectl apply -f logs-viewer.yaml
kubectl get pods -n default -l app=logs-viewer
```

---

## 5) Add Helm Repo (GitHub Pages)

```bash
helm repo remove self-heal 2>/dev/null || true
helm repo add self-heal https://<GITHUB_USERNAME>.github.io/<REPO_NAME>
helm repo update
helm search repo self-heal
```

You should see:

* self-heal/disk-usage
* self-heal/cpu-usage
* self-heal/cpu-precheck (if present)

---

## 6) Install disk-usage chart

```bash
helm uninstall disk-usage -n default 2>/dev/null || true

helm install disk-usage self-heal/disk-usage -n default --create-namespace \
  --set-string secrets.SMTP_PASSWORD="YOUR_SMTP_APP_PASSWORD"
```

Verify:

```bash
kubectl get cronjob -n default | grep disk-usage
kubectl get pods -n default | grep disk-usage || true
kubectl get pvc -n default | grep -E "disk-usage|self-heal-logs-pvc"
```

---

## 7) Manual test run (don’t wait for cron)

This forces the CronJob to run immediately.

```bash
JOB="disk-usage-manual-$(date +%Y%m%d-%H%M%S)"
kubectl create job --from=cronjob/disk-usage-disk-usage-cron "$JOB" -n default

POD=$(kubectl get pods -n default -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n default -f "$POD"
```

Expected output example:

* Node minikube is healthy: 7%
* All 1 nodes healthy. Highest usage=7% on minikube

---

## 8) Confirm debug pod creation (optional check)

During execution, it creates a temporary pod like:
`node-debugger-<node>-xxxxx`

To see it live, run in another terminal while job is running:

```bash
kubectl get pods -n default | grep node-debugger || true
```

✅ After each node check, the script deletes the debugger pod automatically.

---

## 9) View logs via logs-viewer (recommended)

```bash
kubectl exec -it -n default deploy/logs-viewer -- sh
ls -lh /opt/logs
tail -f /opt/logs/diskcheck_$(date +%Y-%m-%d).log
```

---

## 10) Cleanup (optional)

```bash
helm uninstall disk-usage -n default
```

(If you want full cleanup)

```bash
kubectl delete -f logs-viewer.yaml
kubectl delete -f shared-logs-pvc.yaml
```

Done ✅

---

