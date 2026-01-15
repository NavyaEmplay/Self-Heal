#!/bin/bash

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" | tee -a "$LOG_DIR/cpuprecheck_$(date '+%Y-%m-%d').log"
}

retry_with_config() {
  local cmd=$1 retries=$2 interval=$3 count=0
  until $cmd; do
    count=$((count+1))
    [ $count -ge $retries ] && return 1
    log "DEBUG" "Retry $count/$retries failed, sleeping $interval"
    sleep $interval
  done
  return 0
}

can_alert() {
  local cooldown=$1 file=/opt/state/last_precheck_alert now=$(date +%s)
  if [ -f $file ]; then
    last=$(<$file)
    if (( last + cooldown > now )); then
      remain=$(( last + cooldown - now ))
      log "INFO" "Cooldown active, skipping precheck report (wait ${remain}s more)"
      return 1
    fi
  fi
  echo $now > $file
  return 0
}

report_issue() {
  local msg=$1
  log "REPORT" "$msg"
  # extend later: webhook / ticket / alert manager etc.
}
