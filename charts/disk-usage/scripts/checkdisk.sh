#!/bin/bash
set -euo pipefail

source /opt/config/config.env
source /opt/utils/utils.sh

mkdir -p "$LOG_DIR" /opt/state
find "$LOG_DIR" -type f -name "diskcheck_*.log" -mtime +7 -delete || true

NAMESPACE="${POD_NAMESPACE:-default}"
DEBUG_IMAGE="${DEBUG_IMAGE:-ubuntu:24.04}"
DEBUG_SLEEP="${DEBUG_SLEEP_SECONDS:-120}"

cleanup_all_debuggers() {
  # delete any old debugger pods from previous runs
  kubectl get pods -n "$NAMESPACE" -o name 2>/dev/null \
    | grep '^pod/node-debugger-' \
    | xargs -r kubectl delete -n "$NAMESPACE" --now >/dev/null 2>&1 || true
}

create_debugger_for_node() {
  local node="$1" base pod
  base="$(basename "$node")"

  # create a node debugger pod (kubectl creates a pod named node-debugger-<node>-xxxxx)
  kubectl debug "$node" --image="$DEBUG_IMAGE" -- sleep "$DEBUG_SLEEP" >/dev/null 2>&1 || true

  # find the created pod
  for i in {1..30}; do
    pod="$(kubectl get pods -n "$NAMESPACE" -o name 2>/dev/null | grep "node-debugger-${base}-" | head -n1 || true)"
    if [ -n "$pod" ]; then
      pod="${pod#pod/}"
      kubectl wait -n "$NAMESPACE" --for=condition=Ready "pod/$pod" --timeout=60s >/dev/null 2>&1 || true
      echo "$pod"
      return 0
    fi
    sleep 2
  done
  return 1
}

get_root_disk_percent_from_node() {
  local pod="$1"
  # chroot into host filesystem mounted at /host (default behavior of kubectl debug node)
  # use df -P for stable output: Filesystem Size Used Avail Use% Mounted
  kubectl exec -n "$NAMESPACE" "$pod" -- chroot /host bash -lc \
    "df -P / | awk 'NR==2 {gsub(/%/,\"\",\$5); print \$5}'" 2>/dev/null || true
}

check_disk() {
  log "DEBUG" "Checking disk usage across all nodes (df / on host via kubectl debug)..."

  cleanup_all_debuggers

  local alert=0 max_usage=0 max_node="" total_count=0
  local today_log="$LOG_DIR/diskcheck_$(date '+%Y-%m-%d').log"

  echo "Node,DiskPercent" | tee -a "$today_log" >/dev/null

  for node in $(kubectl get nodes -o name); do
    local pod usage percent

    pod="$(create_debugger_for_node "$node" || true)"
    if [ -z "${pod:-}" ]; then
      log "ERROR" "Failed to create debugger for $node"
      continue
    fi

    usage="$(get_root_disk_percent_from_node "$pod" | tr -d '\r\n ' | head -n1 || true)"

    # cleanup pod immediately
    kubectl delete pod -n "$NAMESPACE" "$pod" --now >/dev/null 2>&1 || true

    if [ -z "$usage" ] || ! echo "$usage" | grep -Eq '^[0-9]+$'; then
      log "ERROR" "Could not fetch disk usage for $node"
      continue
    fi

    percent="$usage"
    total_count=$((total_count+1))

    echo "$(basename "$node"),${percent}%" | tee -a "$today_log" >/dev/null

    if [ "$percent" -ge "$DISK_THRESHOLD" ]; then
      log "WARNING" "Node $(basename "$node") is above threshold: ${percent}%"
      alert=1
    else
      log "INFO" "Node $(basename "$node") is healthy: ${percent}%"
    fi

    if [ "$percent" -gt "$max_usage" ]; then
      max_usage="$percent"
      max_node="$(basename "$node")"
    fi
  done

  echo "$max_node" > /opt/state/max_node
  echo "$max_usage" > /opt/state/max_usage

  if [ "$total_count" -eq 0 ]; then
    log "ERROR" "No nodes were successfully checked (debug/df failed)"
    return 1
  fi

  if [ "$alert" -eq 0 ]; then
    log "INFO" "All $total_count nodes healthy. Highest usage=${max_usage}% on ${max_node}"
    return 0
  else
    log "ERROR" "High Disk detected. Worst=${max_usage}% on ${max_node}"
    return 1
  fi
}

if retry_with_config check_disk "$RETRY_COUNT" "$RETRY_INTERVAL"; then
  exit 0
else
  if can_alert "$COOLDOWN_PERIOD"; then
    NODE=$(cat /opt/state/max_node 2>/dev/null || echo "")
    USAGE=$(cat /opt/state/max_usage 2>/dev/null || echo "0")
    if [ -n "$NODE" ]; then
      send_email "$NODE" "$USAGE"
      log "INFO" "Email sent (Node=$NODE, Usage=$USAGE%)"
    fi
  fi
  exit 0
fi
