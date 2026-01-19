#!/bin/bash
set -euo pipefail

source /opt/config/config.env
source /opt/utils/utils.sh

mkdir -p "$LOG_DIR" /opt/state
find "$LOG_DIR" -type f -name "diskwrite_*.log" -mtime +7 -delete || true

check_disk_write() {
  log "DEBUG" "Checking disk write capability..."
  local f="$TEST_PATH/self_heal_disk_write_test_$$"

  if ! echo "test" > "$f" 2>/dev/null; then
    log "WARNING" "Disk write FAILED: could not write $f"
    echo "$NODE_NAME" > /opt/state/max_node 2>/dev/null || true
    echo "Disk write failed at $f" > /opt/state/fail_reason 2>/dev/null || true
    return 1
  fi

  if [ "${KEEP_FILE:-0}" = "1" ]; then
    log "INFO" "KEEP_FILE=1 → leaving $f for manual verification"
    sleep 60
  else
    rm -f "$f" 2>/dev/null || true
  fi

  log "INFO" "Disk write OK at $TEST_PATH (node: ${NODE_NAME:-unknown})"
  echo "$NODE_NAME" > /opt/state/max_node 2>/dev/null || true
  echo "OK" > /opt/state/fail_reason 2>/dev/null || true
  return 0
}

if retry_with_config check_disk_write "$RETRY_COUNT" "$RETRY_INTERVAL"; then
  exit 0
else
  log "ERROR" "Disk write issue persisted after retries."

  if can_alert "$COOLDOWN_PERIOD"; then
    NODE=$(cat /opt/state/max_node 2>/dev/null || echo "${NODE_NAME:-unknown}")
    REASON=$(cat /opt/state/fail_reason 2>/dev/null || echo "Disk write failed")
    send_email "$NODE" "$REASON"
    log "INFO" "Email sent (Node=$NODE)"
  fi

  exit 0
fi
