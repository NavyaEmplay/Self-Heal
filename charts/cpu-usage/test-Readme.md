
# ✅ README-2.md (Tester/New User: Install Tools → Add Repo → Install Chart → Test → Logs)

```md
# Self-Heal Helm Repo (Tester/New User Guide)
This guide is for a **new person / new VM** to install required tools, connect to a Kubernetes cluster, install the chart, run a manual test, and view logs.

---

## 1) Prerequisites
- Ubuntu VM
- Internet access
- Kubernetes cluster available:
  - Either minikube OR EKS/AKS etc.
- `kubectl` configured and working:
  ```bash
  kubectl get nodes
2) Install required tools (Ubuntu)
bash
Copy code
sudo apt-get update -y
sudo apt-get install -y git curl ca-certificates
Install Helm
bash
Copy code
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
Install kubectl
bash
Copy code
curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client
3) If using Minikube (optional)
If your new VM is using minikube:

bash
Copy code
sudo apt-get install -y docker.io
sudo usermod -aG docker $USER
newgrp docker

curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube

minikube start --driver=docker
kubectl get nodes
4) Enable Metrics Server (IMPORTANT)
The cpu-usage chart uses kubectl top nodes.

If Minikube:
bash
Copy code
minikube addons enable metrics-server
kubectl get pods -n kube-system | grep metrics
kubectl top nodes
If you get metrics not available yet, wait 30–60 seconds and retry.

5) Clone repo (needed for shared PVC + logs-viewer YAML)
bash
Copy code
mkdir -p ~/test-self-heal
cd ~/test-self-heal

git clone https://github.com/<GITHUB_USERNAME>/<REPO_NAME>.git
cd <REPO_NAME>
ls
You should see:

shared-logs-pvc.yaml

logs-viewer.yaml

6) Create shared logs PVC (ONE TIME per cluster)
⚠️ This must be created ONCE. Do not create repeatedly.

bash
Copy code
kubectl apply -f shared-logs-pvc.yaml
kubectl get pvc -n default | grep self-heal-logs-pvc
PVC must become Bound.

7) Deploy Logs Viewer (ONE TIME per cluster)
This keeps a pod always running so you can go inside and check all logs from a single place.

bash
Copy code
kubectl apply -f logs-viewer.yaml
kubectl get pods -n default -l app=logs-viewer
Wait until it shows Running.

8) Add Helm repo (from GitHub Pages)
bash
Copy code
helm repo remove self-heal 2>/dev/null || true
helm repo add self-heal https://<GITHUB_USERNAME>.github.io/<REPO_NAME>
helm repo update
helm search repo self-heal
You should see:

self-heal/cpu-usage

9) Install cpu-usage chart
bash
Copy code
helm uninstall cpu-usage -n default 2>/dev/null || true

helm install cpu-usage self-heal/cpu-usage -n default --create-namespace \
  --set-string secrets.SMTP_PASSWORD="YOUR_SMTP_APP_PASSWORD"
Verify:

bash
Copy code
kubectl get cronjob -n default | grep cpu-usage
kubectl get pvc -n default | grep -E "cpu-usage-state|self-heal-logs-pvc"
10) Manual test run (run now, don’t wait for schedule)
bash
Copy code
JOB="cpu-usage-manual-$(date +%Y%m%d-%H%M%S)"
kubectl create job --from=cronjob/cpu-usage-cpu-usage-cron "$JOB" -n default

POD=$(kubectl get pods -n default -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n default -f "$POD"
11) View logs in one place (logs-viewer pod)
Enter viewer container
bash
Copy code
kubectl exec -it -n default deploy/logs-viewer -- sh
Inside:

sh
Copy code
ls -lh /opt/logs
tail -f /opt/logs/cpucheck_$(date +%Y-%m-%d).log
Exit:

sh
Copy code
exit
12) Why you must NOT create shared PVC using kubectl AND helm both
If the chart tries to create self-heal-logs-pvc AND you also created it using kubectl,
Helm will fail with an error like:

PVC exists and cannot be imported into the current release ... missing meta.helm.sh annotations

✅ Correct process:

Create self-heal-logs-pvc manually ONCE (kubectl apply)

Chart only REFERENCES it (claimName)

13) Cleanup (optional)
bash
Copy code
helm uninstall cpu-usage -n default
kubectl delete -f logs-viewer.yaml
kubectl delete -f shared-logs-pvc.yaml
Done ✅

yaml
Copy code

---
