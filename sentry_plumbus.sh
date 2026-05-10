#!/bin/bash
# ── The P.L.U.M.B.U.S. Sentry ─────────────────────────────────
#  Real-time trade monitoring and instant Telegram alerts.
#  Run every 15 minutes via cron.
# ──────────────────────────────────────────────────────────────

set -euo pipefail

# Get the directory where the script is located
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"
export PATH="/usr/bin:/usr/local/bin:$PATH"

ENV_FILE=".env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

STATE_FILE="./trade_state.json"
HISTORY_FILE="./trade_history.json"
PHEMEX_SPOT="https://api.phemex.com/md/spot/ticker/24hr/all"
PHEMEX_PERP="https://api.phemex.com/md/v3/ticker/24hr/all"
RETRY_MAX=3
RETRY_DELAY=2

# ── Helpers ───────────────────────────────────────────────────
normalize_decimal() {
  echo "$1" | sed 's/^\./0./; s/^-\./-0./'
}

fetch_json() {
  local url="$1" out="$2" label="$3" attempt=1 delay="$RETRY_DELAY"
  while (( attempt <= RETRY_MAX )); do
    if curl -sfL --max-time 15 "$url" -o "$out" 2>/dev/null; then
      if jq -e '.result | type == "array"' "$out" >/dev/null 2>&1; then return 0; fi
    fi
    (( attempt++ ))
    [[ $attempt -le $RETRY_MAX ]] && sleep "$delay"
    delay=$(( delay * 2 ))
  done
  return 1
}

# ── Mutex Lock ────────────────────────────────────────────────
# Prevent multiple sentry instances from running concurrently
LOCKFILE="/tmp/plumbus_sentry.lock"
exec 200>"$LOCKFILE"
flock -n 200 || exit 0

# ── Heartbeat ─────────────────────────────────────────────────
# Pulse the heartbeat to prove the cron is alive
touch .plumbus_heartbeat

# ── Exit early if no open trade ───────────────────────────────
[[ -f "$STATE_FILE" ]] || exit 0
STATE=$(cat "$STATE_FILE")
OPEN_TRADE=$(echo "$STATE" | jq -c '.open_trade // empty')
[[ -n "$OPEN_TRADE" && "$OPEN_TRADE" != "null" ]] || exit 0

SYMBOL=$(echo "$OPEN_TRADE"     | jq -r '.symbol')
DISPLAY_SYMBOL=$(echo "$SYMBOL" | sed 's/^s//')
SL=$(echo "$OPEN_TRADE"         | jq -r '.sl')
TP1=$(echo "$OPEN_TRADE"        | jq -r '.tp1')
TP2=$(echo "$OPEN_TRADE"        | jq -r '.tp2')
TP3=$(echo "$OPEN_TRADE"        | jq -r '.tp3')
OPENED_TS=$(echo "$OPEN_TRADE"  | jq -r '.opened // 0')
LAST_STATUS=$(echo "$STATE"     | jq -r '.last_status // "NONE"')

# ── Fetch market data ─────────────────────────────────────────
TMP_SPOT=$(mktemp); TMP_PERP=$(mktemp)
trap 'rm -f "$TMP_SPOT" "$TMP_PERP"' EXIT INT TERM

fetch_json "$PHEMEX_SPOT" "$TMP_SPOT" "Spot" &
fetch_json "$PHEMEX_PERP" "$TMP_PERP" "Perp" &
wait

# ── Normalize current price ────────────────────────────────────
IS_SPOT=$(jq -r ".result[] | select(.symbol==\"$SYMBOL\") | has(\"lastEp\")" "$TMP_SPOT" 2>/dev/null \
  | head -1 || echo "false")

if [[ "$IS_SPOT" == "true" ]]; then
  RAW_EP=$(jq -r ".result[] | select(.symbol==\"$SYMBOL\") | .lastEp // 0" "$TMP_SPOT" 2>/dev/null | head -1)
  CURRENT_PRICE=$(normalize_decimal "$(echo "scale=10; ${RAW_EP:-0} / 100000000" | bc -l)")
else
  CURRENT_PRICE=$(jq -r ".result[] | select(.symbol==\"$SYMBOL\") | .lastRp // 0" "$TMP_PERP" 2>/dev/null | head -1)
fi

[[ -n "$CURRENT_PRICE" && "$CURRENT_PRICE" != "0" ]] || exit 0

# ── Evaluate price against levels ─────────────────────────────
NEW_STATUS="$LAST_STATUS"
ALERT_MSG=""

if (( $(echo "$CURRENT_PRICE <= $SL" | bc -l) )); then
  NEW_STATUS="STOP_LOSS"
  ALERT_MSG="🚨 <b>STOP LOSS TRIGGERED</b>

Ticker: <code>$DISPLAY_SYMBOL</code>
Exit:   <code>$CURRENT_PRICE</code>

Trade closed. Full post-mortem in the next transmission."

elif (( $(echo "$CURRENT_PRICE >= $TP3" | bc -l) )); then
  NEW_STATUS="TP3"
  ALERT_MSG="💰 <b>TAKE PROFIT 3 — FULL EXIT</b>

Ticker: <code>$DISPLAY_SYMBOL</code>
Exit:   <code>$CURRENT_PRICE</code>

Maximum target reached. Trade closed."

elif (( $(echo "$CURRENT_PRICE >= $TP2" | bc -l) )); then
  if [[ "$LAST_STATUS" != "TP2" && "$LAST_STATUS" != "TP3" ]]; then
    NEW_STATUS="TP2"
    ALERT_MSG="🎯 <b>TAKE PROFIT 2 REACHED</b>

Ticker: <code>$DISPLAY_SYMBOL</code>
Price:  <code>$CURRENT_PRICE</code>

Consider trailing stop. Watching for TP3 at $TP3."
  fi

elif (( $(echo "$CURRENT_PRICE >= $TP1" | bc -l) )); then
  if [[ "$LAST_STATUS" == "NEW_TRADE" || "$LAST_STATUS" == "RUNNING" ]]; then
    NEW_STATUS="TP1"
    ALERT_MSG="🎯 <b>TAKE PROFIT 1 REACHED</b>

Ticker: <code>$DISPLAY_SYMBOL</code>
Price:  <code>$CURRENT_PRICE</code>

First milestone secured. Move stop to entry."
  fi
fi

# ── Act on status change ───────────────────────────────────────
if [[ "$NEW_STATUS" != "$LAST_STATUS" && -n "$ALERT_MSG" ]]; then

  UPDATED_OPEN="$OPEN_TRADE"

  if [[ "$NEW_STATUS" == "STOP_LOSS" || "$NEW_STATUS" == "TP3" ]]; then
    UPDATED_OPEN="null"
    # ... history logging logic ...
  elif [[ "$NEW_STATUS" == "TP1" ]]; then
    # Move SL to Entry
    entry_px=$(echo "$OPEN_TRADE" | jq -r '.entry')
    UPDATED_OPEN=$(echo "$OPEN_TRADE" | jq -c --arg e "$entry_px" '.sl = ($e|tonumber)')
  fi

  # Dedup: only log if this specific trade session hasn't been closed in history
  if [[ "$NEW_STATUS" == "STOP_LOSS" || "$NEW_STATUS" == "TP3" ]]; then
    ALREADY=$(jq -s "map(select(.symbol==\"$SYMBOL\" and .opened==$OPENED_TS and .result==\"$NEW_STATUS\")) | length" \
      "$HISTORY_FILE" 2>/dev/null || echo 0)

    if [[ "$ALREADY" == "0" ]]; then
      jq -n \
        --argjson t "$OPEN_TRADE" \
        --arg exit "$CURRENT_PRICE" \
        --arg status "$NEW_STATUS" \
        '$t + {exit_price:($exit|tonumber), result:$status, closed_at:now}' >> "$HISTORY_FILE"
    fi
  fi

  # Update state file
  jq -n \
    --argjson open "$UPDATED_OPEN" \
    --arg status "$NEW_STATUS" \
    '{open_trade:$open, last_status:$status}' > "$STATE_FILE"

  # Send Telegram alert
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
      -d chat_id="$TELEGRAM_CHAT_ID" \
      -d parse_mode="HTML" \
      --data-urlencode "text=$ALERT_MSG" >/dev/null
  fi
fi
