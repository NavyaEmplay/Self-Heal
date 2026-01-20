#!/bin/bash
set -euo pipefail

source /opt/config/config.env
source /opt/utils/utils.sh

mkdir -p "$LOG_DIR" /opt/state
find "$LOG_DIR" -type f -name "memoryalert_*.log" -mtime +7 -delete || true

check_memory() {
  log "DEBUG" "Checking Memory usage across all nodes..."
  alert=0
  max_usage=0
  max_node=""
  total_count=0

  # kubectl top nodes columns:
  # NAME CPU(cores) CPU% MEMORY(bytes) MEMORY%
  while read -r node cpu cpu_pct mem_bytes mem_pct; do
    usage="${mem_pct%\%}"
    total_count=$((total_count+1))

    if [ "$usage" -ge "$MEMORY_THRESHOLD" ]; then
      log "WARNING" "Node $node is above memory threshold: ${usage}%"
      alert=1
    else
      log "INFO" "Node $node memory healthy: ${usage}%"
    fi

    if [ "$usage" -gt "$max_usage" ]; then
      max_usage=$usage
      max_node=$node
    fi
  done < <(kubectl top nodes --no-headers | awk '{print $1, $2, $3, $4, $5}')

  echo "$max_node" > /opt/state/max_memory_node
  echo "$max_usage" > /opt/state/max_memory_usage

  if [ $alert -eq 0 ]; then
    log "INFO" "All $total_count nodes memory healthy. Highest usage=$max_usage% on $max_node"
  else
    log "ERROR" "High Memory detected. Worst=$max_usage% on $max_node"
  fi

  return $alert
}

on_persisting_high_memory() {
  if can_alert "$COOLDOWN_PERIOD"; then
    NODE=$(cat /opt/state/max_memory_node 2>/dev/null || echo "")
    USAGE=$(cat /opt/state/max_memory_usage 2>/dev/null || echo "0")
    if [ -n "$NODE" ]; then
      send_email "$NODE" "$USAGE"
      log "INFO" "Email sent (Node=$NODE, Usage=$USAGE%)"
    else
      log "ERROR" "No node info available to send email."
    fi
  else
    log "DEBUG" "Email skipped due to cooldown."
  fi
}

log "DEBUG" "Running checkmemory_alert.sh"

if retry_with_config check_memory "$RETRY_COUNT" "$RETRY_INTERVAL"; then
  log "DEBUG" "Memory usage under control."
  exit 0
else
  log "ERROR" "Memory still high after retries."
  on_persisting_high_memory
  exit 0
fi
