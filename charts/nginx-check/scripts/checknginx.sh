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
