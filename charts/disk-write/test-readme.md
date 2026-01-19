---

# ✅ README-2 (Tester) — disk-write (UPDATED with “verify file” section)

Save as: `charts/disk-write/test-Readme.md`

```md
# disk-write Helm Chart (Tester/New User Guide)

This guide is for a new person/new VM to:
✅ install tools  
✅ connect to cluster  
✅ install disk-write from GitHub Pages Helm repo  
✅ run manual job  
✅ verify the created file (KEEP_FILE=1)  
✅ view logs

---

## 1) Prerequisites
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

---

## 4) Install disk-write

```bash
helm uninstall disk-write -n default 2>/dev/null || true

helm install disk-write self-heal/disk-write -n default --create-namespace \
  --set-string secrets.SMTP_PASSWORD="YOUR_GMAIL_APP_PASSWORD"
```

Verify:

```bash
kubectl get cronjob -n default | grep disk-write
```

---

## 5) Manual run (don’t wait for cron)

```bash
JOB="disk-write-manual-$(date +%Y%m%d-%H%M%S)"
kubectl create job --from=cronjob/disk-write-disk-write-cron "$JOB" -n default

POD=$(kubectl get pods -n default -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n default -f "$POD"
```

---

## 6) Manual verification (KEEP_FILE=1) — verify file exists

### Option A: Temporary debug pod on same node

```bash
NODE=$(kubectl get pod -n default "$POD" -o jsonpath='{.spec.nodeName}')

kubectl run diskwrite-check -n default --rm -it --image=alpine:3.20 --overrides='
{
  "apiVersion":"v1",
  "spec":{
    "nodeName":"'"$NODE"'",
    "containers":[{
      "name":"c",
      "image":"alpine:3.20",
      "command":["/bin/sh"],
      "stdin":true,
      "tty":true,
      "volumeMounts":[{"name":"host-tmp","mountPath":"/host/tmp"}]
    }],
    "volumes":[{"name":"host-tmp","hostPath":{"path":"/tmp","type":"Directory"}}]
  }
}'
```

Inside:

```sh
ls -lh /host/tmp | grep self_heal_disk_write_test || true
cat /host/tmp/self_heal_disk_write_test_* 2>/dev/null || true
```

### Option B: Minikube only

```bash
minikube ssh
ls -lh /tmp | grep self_heal_disk_write_test || true
cat /tmp/self_heal_disk_write_test_* 2>/dev/null || true
exit
```

---

## 7) View logs

```bash
kubectl exec -it -n default deploy/logs-viewer -- sh
tail -f /opt/logs/diskwrite_$(date +%Y-%m-%d).log
```

Done ✅

```

---

