
# ✅ README-2.md (Tester/New VM) — Install → Manual Run → View Logs

Save as: `charts/nginx-check/test-Readme.md`

```md
# nginx-check Helm Chart (Tester/New User Guide)

This guide is for a tester/new VM to:
✅ setup nginx ingress controller (if missing)  
✅ add Helm repo  
✅ install nginx-check  
✅ run manual job  
✅ view logs from logs-viewer  

---

## 1) Pre-checks
kubectl works:
```bash
kubectl get nodes
````

Helm works:

```bash
helm version
```

---

## 2) Ensure nginx ingress controller exists (required)

### Option A (Minikube)

```bash
minikube addons enable ingress
kubectl get pods -n ingress-nginx
```

### Option B (Helm install)

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace

kubectl get pods -n ingress-nginx
```

---

## 3) Create a sample app + ingress (recommended test)

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

Optional curl test (Minikube):

```bash
minikube tunnel
curl -H "Host: demo.local" http://127.0.0.1/
```

---

## 4) Add Helm repo (GitHub Pages)

```bash
helm repo remove self-heal 2>/dev/null || true
helm repo add self-heal https://NavyaEmplay.github.io/Self-Heal
helm repo update
helm search repo self-heal
```

You should see:

* self-heal/nginx-check

---

## 5) Install nginx-check chart

```bash
helm uninstall nginx-check -n default 2>/dev/null || true

helm install nginx-check self-heal/nginx-check -n default --create-namespace \
  --set-string secrets.SMTP_PASSWORD="YOUR_SMTP_APP_PASSWORD"
```

Verify:

```bash
kubectl get cronjob -n default | grep nginx-check
kubectl get pods -n default | grep nginx-check
```

---

## 6) Manual run test (run now)

```bash
JOB="nginx-check-manual-$(date +%Y%m%d-%H%M%S)"
kubectl create job --from=cronjob/nginx-check-nginx-check-cron "$JOB" -n default

POD=$(kubectl get pods -n default -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n default -f "$POD"
```

Expected success logs:

* `All nginx ingress pods are Ready`

---

## 7) View logs from logs-viewer

```bash
kubectl exec -it -n default deploy/logs-viewer -- sh
ls -lh /opt/logs
tail -f /opt/logs/nginxcheck_$(date '+%Y-%m-%d').log
```

---

## 8) Cleanup (optional)

```bash
helm uninstall nginx-check -n default
kubectl delete ingress demo-echo-ingress -n default
kubectl delete svc demo-echo-svc -n default
kubectl delete deploy demo-echo -n default
```

Done ✅

````

---

## Quick note (so you don’t get confused)
Your original script used:
- namespace: `default`
- selector: `app.kubernetes.io/name=nginx-ingress`

But real ingress-nginx usually is:
- namespace: `ingress-nginx`
- selector: `app.kubernetes.io/name=ingress-nginx`

That’s why I made it configurable in `values.yaml`. If your nginx pods truly run in default with your label, just change:

```yaml
NGINX_NAMESPACE: "default"
NGINX_LABEL_SELECTOR: "app.kubernetes.io/name=nginx-ingress"
````

If you paste your `kubectl get pods -A | grep nginx` output, I can tell you the exact right selector/namespace for your cluster.
