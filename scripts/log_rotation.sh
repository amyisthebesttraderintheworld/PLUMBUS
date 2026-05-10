#!/bin/bash
# Log rotation and management utility for PLUMBUS

set -euo pipefail

# Configuration
LOG_DIR="${LOG_DIR:-.}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/plumbus.log}"
MAX_LOG_SIZE="${MAX_LOG_SIZE:-10485760}"  # 10MB
MAX_LOG_AGE="${MAX_LOG_AGE:-30}"          # days
BACKUP_LOGS="${BACKUP_LOGS:-5}"           # number of backups to keep

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RESET='\033[0m'

log_info() { echo -e "${GREEN}ℹ${RESET}  $1"; }
log_warn() { echo -e "${YELLOW}⚠${RESET}  $1"; }
log_error() { echo -e "${RED}✖${RESET}  $1"; }

# Compress old logs
compress_old_logs() {
  local logfile="$1"
  local backup_dir="${logfile}.d"
  
  [[ ! -d "$backup_dir" ]] && mkdir -p "$backup_dir"
  
  # Find and compress logs older than 1 day
  find "$backup_dir" -name "*.log" -type f ! -name "*gz" -mtime +0 -exec gzip {} \;
  
  log_info "Compressed old log files in $backup_dir"
}

# Rotate log file
rotate_log() {
  local logfile="$1"
  local backup_dir="${logfile}.d"
  local timestamp=$(date +%Y%m%d_%H%M%S)
  local backup_file="$backup_dir/${logfile##*/}.${timestamp}"
  
  [[ ! -d "$backup_dir" ]] && mkdir -p "$backup_dir"
  
  if [[ -f "$logfile" ]]; then
    # Check file size
    local size=$(stat -f%z "$logfile" 2>/dev/null || stat -c%s "$logfile" 2>/dev/null || echo 0)
    
    if [[ $size -gt $MAX_LOG_SIZE ]]; then
      mv "$logfile" "$backup_file"
      touch "$logfile"
      log_info "Rotated log file: $logfile -> $backup_file"
      
      # Compress the rotated file
      gzip "$backup_file" &
    fi
  fi
}

# Clean up old log backups
cleanup_old_backups() {
  local logfile="$1"
  local backup_dir="${logfile}.d"
  
  if [[ -d "$backup_dir" ]]; then
    # Remove backups older than MAX_LOG_AGE days
    find "$backup_dir" -name "*.gz" -type f -mtime +"$MAX_LOG_AGE" -delete
    
    # Keep only the most recent backups if needed
    local backup_count=$(find "$backup_dir" -name "*.gz" -type f | wc -l)
    if [[ $backup_count -gt $BACKUP_LOGS ]]; then
      ls -t "$backup_dir"/*.gz 2>/dev/null | tail -n +"$((BACKUP_LOGS + 1))" | xargs -r rm
      log_info "Cleaned up old backups, keeping latest $BACKUP_LOGS"
    fi
  fi
}

# Main rotation logic
rotate_if_needed() {
  local logfile="$1"
  
  if [[ ! -f "$logfile" ]]; then
    touch "$logfile"
    log_info "Created new log file: $logfile"
    return
  fi
  
  rotate_log "$logfile"
  compress_old_logs "$logfile"
  cleanup_old_backups "$logfile"
}

# Show log statistics
show_stats() {
  local logfile="$1"
  local backup_dir="${logfile}.d"
  
  if [[ -f "$logfile" ]]; then
    local size=$(stat -f%z "$logfile" 2>/dev/null || stat -c%s "$logfile" 2>/dev/null || echo 0)
    local lines=$(wc -l < "$logfile" | tr -d ' ')
    
    local human_size
    if [[ $size -ge 1048576 ]]; then
      human_size="$(echo "scale=2; $size / 1048576" | bc)MB"
    elif [[ $size -ge 1024 ]]; then
      human_size="$(echo "scale=2; $size / 1024" | bc)KB"
    else
      human_size="${size}B"
    fi
    
    log_info "Current log: $logfile ($lines lines, $human_size)"
    
    if [[ -d "$backup_dir" ]]; then
      local backup_count=$(find "$backup_dir" -type f | wc -l)
      local total_backup_size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)
      log_info "Backup directory: $backup_dir ($backup_count files, $total_backup_size)"
    fi
  else
    log_warn "Log file not found: $logfile"
  fi
}

# Parse arguments
case "${1:-rotate}" in
  rotate)
    rotate_if_needed "$LOG_FILE"
    ;;
  stats)
    show_stats "$LOG_FILE"
    ;;
  cleanup)
    cleanup_old_backups "$LOG_FILE"
    ;;
  *)
    echo "Usage: $0 {rotate|stats|cleanup}"
    echo ""
    echo "  rotate  - Rotate and compress log files if needed (default)"
    echo "  stats   - Show log statistics"
    echo "  cleanup - Clean up old backups"
    echo ""
    echo "Environment variables:"
    echo "  LOG_DIR       - Directory containing logs (default: .)"
    echo "  LOG_FILE      - Path to log file (default: $LOG_DIR/plumbus.log)"
    echo "  MAX_LOG_SIZE  - Max size before rotation in bytes (default: 10485760)"
    echo "  MAX_LOG_AGE   - Max age of backups in days (default: 30)"
    echo "  BACKUP_LOGS   - Number of backups to keep (default: 5)"
    exit 1
    ;;
esac
