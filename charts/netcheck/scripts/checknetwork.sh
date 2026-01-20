#!/bin/bash
set -euo pipefail

source /opt/config/config.env
source /opt/utils/utils.sh

mkdir -p "$LOG_DIR" /opt/state
find "$LOG_DIR" -type f -name "netcheck_*.log" -mtime +7 -delete || true

check_network() {
  log "DEBUG" "Checking network connectivity to $NETWORK_TARGET_URL..."
  if curl -s --max-time "$CURL_TIMEOUT" "$NETWORK_TARGET_URL" > /dev/null; then
    log "INFO" "Network connectivity healthy (HTTP to $NETWORK_TARGET_URL succeeded)"
    return 0
  else
    log "WARNING" "Network connectivity issue detected (HTTP to $NETWORK_TARGET_URL failed)"
    return 1
  fi
}

if retry_with_config check_network "$RETRY_COUNT" "$RETRY_INTERVAL"; then
  exit 0
else
  if can_alert "$COOLDOWN_PERIOD"; then
    send_email "Connectivity to $NETWORK_TARGET_URL failed in namespace=${POD_NAMESPACE:-default} on host=$(hostname)"
    log "INFO" "Email sent (Target=$NETWORK_TARGET_URL)"
  fi
  exit 0
fi
