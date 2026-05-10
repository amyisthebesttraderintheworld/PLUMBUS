#!/bin/bash
# Health monitoring and alerting for PLUMBUS Trading Bot

set -euo pipefail

# Configuration
STATE_FILE="${STATE_FILE:-./data/trade_state.json}"
TRADE_HISTORY_FILE="${TRADE_HISTORY_FILE:-./data/trade_history.json}"
LOG_FILE="${LOG_FILE:-./plumbus.log}"
HEARTBEAT_FILE="${HEARTBEAT_FILE:-.plumbus_heartbeat}"

# Alert thresholds
MAX_HEARTBEAT_AGE="${MAX_HEARTBEAT_AGE:-1800}"  # 30 minutes
MAX_ERROR_RATE="${MAX_ERROR_RATE:-30}"          # % of logs that are errors
MIN_TRADES_DAILY="${MIN_TRADES_DAILY:-3}"       # minimum trades per day
LOSS_THRESHOLD="${LOSS_THRESHOLD:-5}"           # max consecutive losses

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RESET='\033[0m'

# Logging
info()  { echo -e "${CYAN}▸${RESET} $1"; }
ok()    { echo -e "${GREEN}✔${RESET} $1"; }
warn()  { echo -e "${YELLOW}⚠${RESET}  $1"; }
error() { echo -e "${RED}✖${RESET}  $1"; }

# Check heartbeat
check_heartbeat() {
  info "Checking heartbeat..."
  
  if [[ ! -f "$HEARTBEAT_FILE" ]]; then
    warn "Heartbeat file not found: $HEARTBEAT_FILE"
    return 1
  fi
  
  local last_pulse=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE" 2>/dev/null)
  local now=$(date +%s)
  local age=$((now - last_pulse))
  
  if [[ $age -gt $MAX_HEARTBEAT_AGE ]]; then
    error "Heartbeat stale: ${age}s old (threshold: ${MAX_HEARTBEAT_AGE}s)"
    return 1
  else
    ok "Heartbeat healthy: ${age}s old"
    return 0
  fi
}

# Analyze log errors
analyze_errors() {
  info "Analyzing error rate..."
  
  if [[ ! -f "$LOG_FILE" ]]; then
    warn "Log file not found: $LOG_FILE"
    return 1
  fi
  
  local total_lines=$(wc -l < "$LOG_FILE" | tr -d ' ')
  local error_lines=$(grep -c '\[ERROR\]' "$LOG_FILE" 2>/dev/null || echo 0)
  
  if [[ $total_lines -eq 0 ]]; then
    warn "Log file is empty"
    return 1
  fi
  
  local error_rate=$((error_lines * 100 / total_lines))
  
  if [[ $error_rate -gt $MAX_ERROR_RATE ]]; then
    error "High error rate: ${error_rate}% (threshold: ${MAX_ERROR_RATE}%)"
    echo "Recent errors:"
    tail -10 "$LOG_FILE" | grep '\[ERROR\]' | sed 's/^/  /'
    return 1
  else
    ok "Error rate acceptable: ${error_rate}%"
    return 0
  fi
}

# Check trade performance
check_trade_performance() {
  info "Analyzing trade performance..."
  
  if [[ ! -f "$TRADE_HISTORY_FILE" ]]; then
    warn "Trade history file not found: $TRADE_HISTORY_FILE"
    return 1
  fi
  
  # Count trades in last 24 hours
  local now=$(date +%s)
  local day_ago=$((now - 86400))
  
  local recent_trades=$(jq "[.[] | select(.exit_time > $day_ago)] | length" "$TRADE_HISTORY_FILE" 2>/dev/null || echo 0)
  
  if [[ $recent_trades -lt $MIN_TRADES_DAILY ]]; then
    warn "Low trade activity: $recent_trades trades in last 24h (expected: >$MIN_TRADES_DAILY)"
  else
    ok "Trade activity healthy: $recent_trades trades in last 24h"
  fi
  
  # Check for consecutive losses
  local consecutive_losses=$(jq '[.[-5:] | .[] | select(.pnl < 0)] | length' "$TRADE_HISTORY_FILE" 2>/dev/null || echo 0)
  
  if [[ $consecutive_losses -ge $LOSS_THRESHOLD ]]; then
    warn "High consecutive losses: $consecutive_losses out of 5 last trades"
    return 1
  else
    ok "Loss streak acceptable: $consecutive_losses consecutive losses"
    return 0
  fi
}

# Check state file
check_state() {
  info "Checking bot state..."
  
  if [[ ! -f "$STATE_FILE" ]]; then
    error "State file missing: $STATE_FILE"
    return 1
  fi
  
  local valid=$(jq -e '.' "$STATE_FILE" >/dev/null 2>&1 && echo "yes" || echo "no")
  
  if [[ "$valid" != "yes" ]]; then
    error "State file is corrupted: $STATE_FILE"
    return 1
  fi
  
  local open_trades=$(jq '.open_trade // empty' "$STATE_FILE" | jq length 2>/dev/null || echo 0)
  ok "State file valid (active trades: $open_trades)"
  return 0
}

# Generate health report
generate_report() {
  echo ""
  echo "╔════════════════════════════════════════════════════════════════╗"
  echo "║         PLUMBUS TRADING BOT HEALTH REPORT                      ║"
  echo "╚════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "Report generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo ""
  
  # Run all checks
  local health_status=0
  
  check_heartbeat || health_status=1
  echo ""
  
  check_state || health_status=1
  echo ""
  
  analyze_errors || health_status=1
  echo ""
  
  check_trade_performance || health_status=1
  echo ""
  
  # Overall status
  if [[ $health_status -eq 0 ]]; then
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo -e "║ ${GREEN}Overall Status: HEALTHY${RESET}                                   ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
  else
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo -e "║ ${YELLOW}Overall Status: DEGRADED - Review issues above${RESET}            ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
  fi
  
  return $health_status
}

# Main
generate_report
