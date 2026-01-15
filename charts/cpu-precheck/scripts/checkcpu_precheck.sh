#!/bin/bash
source /opt/config/config.env
source /opt/utils/utils.sh

find "$LOG_DIR" -type f -name "cpuprecheck_*.log" -mtime +7 -delete || true

check_cpu() {
  log "DEBUG" "Checking CPU usage across all nodes (precheck)..."
  alert=0
  max_usage=0
  max_node=""
  total_count=0

  # node + CPU% from kubectl top nodes
  while read -r node cpu mem; do
    usage=${cpu%\%}
    total_count=$((total_count+1))

    if [ "$usage" -ge "$CPU_THRESHOLD" ]; then
      log "WARNING" "Node $node is above threshold: ${usage}%"
      alert=1
    else
      log "INFO" "Node $node is healthy: ${usage}%"
    fi

    if [ "$usage" -gt "$max_usage" ]; then
      max_usage=$usage
      max_node=$node
    fi
  done < <(kubectl top nodes --no-headers | awk '{print $1, $3, $5}')

  echo "$max_node" > /opt/state/max_precheck_node
  echo "$max_usage" > /opt/state/max_precheck_usage

  if [ $alert -eq 0 ]; then
    log "INFO" "All $total_count nodes healthy (precheck). Highest usage=$max_usage% on $max_node"
  else
    log "ERROR" "High CPU detected (precheck). Worst=$max_usage% on $max_node"
  fi

  return $alert
}

report_machine() {
  if can_alert "$COOLDOWN_PERIOD"; then
    NODE=$(cat /opt/state/max_precheck_node)
    USAGE=$(cat /opt/state/max_precheck_usage)
    log "ERROR" "CPU usage critical (precheck). Reporting issue..."
    report_issue "CPU precheck: Node=$NODE, Usage=$USAGE% (Threshold=$CPU_THRESHOLD%)"
  else
    log "DEBUG" "Precheck reporting skipped due to cooldown."
  fi
}

if retry_with_config check_cpu "$RETRY_COUNT" "$RETRY_INTERVAL"; then
  exit 0
else
  report_machine
  exit 0
fi

