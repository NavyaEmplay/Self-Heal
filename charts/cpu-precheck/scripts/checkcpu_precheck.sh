#!/bin/bash
set -e

source /opt/config/config.env
source /opt/utils/utils.sh

# delete logs older than 7 days
find "$LOG_DIR" -type f -name "cpu_precheck_*.log" -mtime +7 -delete || true

check_cpu_precheck() {
  log "DEBUG" "CPU PRECHECK: Checking CPU usage across all nodes..."
  alert=0
  max_usage=0
  max_node=""
  total_count=0

  # kubectl top nodes columns commonly: NAME CPU(cores) CPU% MEMORY(bytes) MEMORY%
  while read -r node cpu mem; do
    usage=${cpu%\%}
    total_count=$((total_count+1))

    if [ "$usage" -ge "$CPU_THRESHOLD" ]; then
      log "WARNING" "CPU PRECHECK: Node $node is above threshold: ${usage}%"
      alert=1
    else
      log "INFO" "CPU PRECHECK: Node $node is healthy: ${usage}%"
    fi

    if [ "$usage" -gt "$max_usage" ]; then
      max_usage=$usage
      max_node=$node
    fi
  done < <(kubectl top nodes --no-headers | awk '{print $1, $3, $5}')

  echo "$max_node" > /opt/state/max_node
  echo "$max_usage" > /opt/state/max_usage

  if [ $alert -eq 0 ]; then
    log "INFO" "CPU PRECHECK: All $total_count nodes healthy. Highest usage=$max_usage% on $max_node"
  else
    log "ERROR" "CPU PRECHECK: High CPU detected. Worst=$max_usage% on $max_node"
  fi

  return $alert
}

if retry_with_config check_cpu_precheck "$RETRY_COUNT" "$RETRY_INTERVAL"; then
  exit 0
else
  if can_alert "$COOLDOWN_PERIOD"; then
    NODE=$(cat /opt/state/max_node 2>/dev/null || echo "unknown-node")
    USAGE=$(cat /opt/state/max_usage 2>/dev/null || echo "0")
    send_email "$NODE" "$USAGE"
    log "INFO" "CPU PRECHECK: Email sent (Node=$NODE, Usage=$USAGE%)"
  fi
  exit 0
fi
