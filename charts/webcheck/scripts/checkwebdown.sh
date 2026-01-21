#!/bin/bash
set -euo pipefail

source /opt/config/config.env
source /opt/utils/utils.sh

mkdir -p "$LOG_DIR" /opt/state
find "$LOG_DIR" -type f -name "webcheck_*.log" -mtime +7 -delete || true

check_web() {
  log "DEBUG" "Checking $URL_TO_CHECK"
  code=$(curl -s -o /dev/null -w "%{http_code}" -L --max-time "$TIMEOUT_DURATION" "$URL_TO_CHECK" || true)

  # accept 2xx or 3xx
  if [[ "$code" =~ ^2|^3 ]]; then
    log "INFO" "✅ Service healthy (HTTP $code)"
    return 0
  else
    log "WARNING" "❌ Service unhealthy (HTTP $code)"
    return 1
  fi
}

restart_service() {
  if can_restart "$COOLDOWN_PERIOD"; then
    log "ERROR" "Restarting Deployment $WEB_DEPLOYMENT_NAME in namespace $WEB_DEPLOYMENT_NAMESPACE"
    kubectl rollout restart deployment "$WEB_DEPLOYMENT_NAME" -n "$WEB_DEPLOYMENT_NAMESPACE"
    send_email
    log "INFO" "✅ Restart triggered + email sent (if enabled)"
  else
    log "INFO" "Restart skipped due to cooldown"
  fi
}

if retry_with_config check_web "$RETRY_COUNT" "$RETRY_INTERVAL"; then
  log "INFO" "✅ Job completed successfully (service healthy)"
  exit 0
else
  log "ERROR" "Web service seems down, attempting restart"
  restart_service
  exit 0
fi
