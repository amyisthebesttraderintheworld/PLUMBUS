#!/bin/bash
# ============================================================
#  The P.L.U.M.B.U.S.
#  (Price Level Updates, Market Briefings, & Universal Signals)
# ============================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────
ENV_FILE="${ENV_FILE:-.env}"
STATE_FILE="${STATE_FILE:-./data/trade_state.json}"
TRADE_HISTORY_FILE="${TRADE_HISTORY_FILE:-./data/trade_history.json}"
MODEL="${NVIDIA_MODEL:-meta-llama/Llama-3.3-70B-Instruct}"
TEMPERATURE="${NVIDIA_TEMPERATURE:-0.6}"
MAX_TOKENS="${NVIDIA_MAX_TOKENS:-4096}"
MIN_VOLUME="${MIN_VOLUME:-10000}"
SAVE_REPORT="${SAVE_REPORT:-false}"
REPORT_DIR="${REPORT_DIR:-./reports}"
RETRY_MAX=3
RETRY_DELAY=2
API_TIMEOUT="${API_TIMEOUT:-15}"
NVIDIA_TIMEOUT="${NVIDIA_TIMEOUT:-60}"
TELEGRAM_TIMEOUT="${TELEGRAM_TIMEOUT:-10}"
PHEMEX_SPOT="https://api.phemex.com/md/spot/ticker/24hr/all"
PHEMEX_PERP="https://api.phemex.com/md/v3/ticker/24hr/all"
NVIDIA_URL="https://api.studio.nebius.ai/v1/chat/completions"
TMPDIR_LOCAL=$(mktemp -d)
LOG_FILE="${LOG_FILE:-./plumbus.log}"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT INT TERM

PREV_BRIEF_FILE="${PREV_BRIEF_FILE:-./data/last_brief.txt}"
PREV_BRIEF=""
[[ -f "$PREV_BRIEF_FILE" ]] && PREV_BRIEF=$(cat "$PREV_BRIEF_FILE")

# ── Colors ────────────────────────────────────────────────────
ESC=$(printf '\033')
RED="${ESC}[0;31m"; YELLOW="${ESC}[1;33m"; GREEN="${ESC}[0;32m"
CYAN="${ESC}[0;36m"; BOLD="${ESC}[1m"; DIM="${ESC}[2m"; RESET="${ESC}[0m"

# ── Helpers ───────────────────────────────────────────────────
log()  { echo -e "${DIM}[$(date +%H:%M:%S)]${RESET} $*" >&2; }
info() { echo -e "${CYAN}▸${RESET} $*" >&2; }
ok()   { echo -e "${GREEN}✔${RESET} $*" >&2; }
warn() { echo -e "${YELLOW}⚠${RESET}  $*" >&2; }
die()  { echo -e "${RED}✖  ERROR:${RESET} $*" >&2; exit 1; }

# Structured logging with timestamp
log_event() {
  local level="$1" msg="$2"
  local ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" >> "$LOG_FILE"
  case "$level" in
    ERROR) die "$msg" ;;
    WARN)  warn "$msg" ;;
    INFO)  info "$msg" ;;
  esac
}

normalize_decimal() {
  # Handles leading dots and ensures consistent decimal output
  echo "$1" | sed 's/^\./0./; s/^-\./-0./'
}

format_price() {
  local p="$1"
  if [[ -z "$p" || "$p" == "0" ]]; then echo "0.00"; return; fi
  # Use printf to avoid scientific notation, then strip trailing zeros
  printf "%.10f" "$p" | sed 's/0*$//; s/\.$//'
}

fetch_json() {
  local url="$1" out="$2" label="$3" attempt=1 delay="$RETRY_DELAY"
  local err_file="${out}.err"
  
  while (( attempt <= RETRY_MAX )); do
    log "Fetching $label (attempt $attempt/$RETRY_MAX)..."
    
    # Capture curl exit code and stderr
    if curl -sfL --max-time "$API_TIMEOUT" --connect-timeout 5 "$url" -o "$out" 2>"$err_file"; then
      if jq -e '.result | type == "array"' "$out" >/dev/null 2>&1; then 
        ok "$label fetched successfully"
        return 0
      else
        local json_err=$(jq -r '.error // .message // "Invalid structure"' "$out" 2>/dev/null || echo "Invalid JSON")
        warn "$label returned invalid JSON structure: $json_err (attempt $attempt/$RETRY_MAX)"
        log_event "WARN" "$label: Invalid JSON - $json_err"
      fi
    else
      curl_exit=$?
      err_msg=$(cat "$err_file" 2>/dev/null | tr '\n' ' ' || echo "Unknown error")
      
      case $curl_exit in
        28) warn "$label API timeout (attempt $attempt/$RETRY_MAX)" ;;
        35) warn "$label SSL error (attempt $attempt/$RETRY_MAX)" ;;
        7)  warn "$label connection failed (attempt $attempt/$RETRY_MAX)" ;;
        *)  warn "$label fetch failed with exit code $curl_exit: $err_msg (attempt $attempt/$RETRY_MAX)" ;;
      esac
      log_event "WARN" "$label fetch failed: exit=$curl_exit, error=$err_msg"
    fi
    
    (( attempt++ ))
    if [[ $attempt -le $RETRY_MAX ]]; then 
      sleep "$delay"
      delay=$(( delay * 2 ))
    fi
  done
  
  echo "FAILED" > "$out.status"
  log_event "ERROR" "All retries exhausted for $label"
  return 1
}

# ── Preflight checks ──────────────────────────────────────────
if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
fi

[[ -n "${NVIDIA_KEY:-}" ]] || die "NVIDIA_KEY is not set. Set it in $ENV_FILE or as an environment variable."
command -v jq   &>/dev/null || die "jq is required but not installed."
command -v curl &>/dev/null || die "curl is required but not installed."
command -v bc   &>/dev/null || die "bc is required but not installed."

# ── Mutex Lock ────────────────────────────────────────────────
LOCKFILE="./data/plumbus_brief.lock"
exec 200>"$LOCKFILE"
flock -n 200 || exit 0

# ── Heartbeat Check ───────────────────────────────────────────
# Ensure the 15-minute sentry is actually running
if [[ -f ".plumbus_heartbeat" ]]; then
  LAST_PULSE=$(stat -c %Y .plumbus_heartbeat)
  NOW=$(date +%s)
  if (( (NOW - LAST_PULSE) > 1800 )); then
    warn "CRON HEARTBEAT FAILURE: Sentry hasn't pulsed in >30 mins."
    # Optional: Send alert to Telegram if credentials exist
  fi
fi

# ── Load data ─────────────────────────────────────────────────
if [[ -f "$STATE_FILE" ]]; then
  TRADE_STATE=$(cat "$STATE_FILE")
else
  TRADE_STATE='{}'
fi
OPEN_TRADE=$(echo "$TRADE_STATE" | jq -c '.open_trade // empty')

if [[ -f "$TRADE_HISTORY_FILE" ]]; then
  TRADE_HISTORY=$(jq -s '.[-10:]' "$TRADE_HISTORY_FILE" 2>/dev/null || echo '[]')
else
  TRADE_HISTORY='[]'
fi

# ── Fetch market data ─────────────────────────────────────────
echo -e "\n${BOLD}  The P.L.U.M.B.U.S.${RESET}  ${DIM}$(date '+%Y-%m-%d %H:%M:%S %Z')${RESET}\n"
info "Fetching market data in parallel…"

SPOT_RAW="$TMPDIR_LOCAL/spot.json"
PERP_RAW="$TMPDIR_LOCAL/perp.json"

fetch_json "$PHEMEX_SPOT" "$SPOT_RAW" "Spot" &
fetch_json "$PHEMEX_PERP" "$PERP_RAW" "Perp" &
wait

[[ -f "$SPOT_RAW.status" || -f "$PERP_RAW.status" ]] && die "One or more data fetches failed."
ok "Raw data fetched."

# ── Compute Signals ────────────────────────────────────────────
info "Computing signals…"

SPOT_SIGNALS=$(jq -c "
  (.result | if type == \"array\" then map(select(type == \"object\")) else [] end) as \$res
  | (\$res | map(select(.openEp != null and (.openEp | tonumber) > 0))) as \$spot
  | {
      SIGNAL_OB: (
        \$spot
        | map(. as \$i | {symbol, changePct: ((((.lastEp | tonumber) - (.openEp | tonumber)) / (.openEp | tonumber)) * 100), lastPx: ((.lastEp | tonumber) / 100000000)})
        | sort_by(.changePct)
        | { MOST_OVERSOLD_PROXY: .[0:5], MOST_OVERBOUGHT_PROXY: (.[-5:] | reverse) }
      ),
      SIGNAL_VOL: (
        \$res | map(select(.lowEp != null and (.lowEp | tonumber) > 0 and (.highEp | tonumber) > (.lowEp | tonumber)))
        | map(. as \$i | {symbol, lastPx: ((.lastEp | tonumber) / 100000000), rangePct: ((((.highEp | tonumber) - (.lowEp | tonumber)) / (.lowEp | tonumber)) * 100)})
        | sort_by(.rangePct)
        | { MAX_INTRADAY_VOLATILITY: (.[-10:] | reverse) }
      ),
      SIGNAL_ALPHA: (
        ((\$res | .[] | select(type == \"object\" and .symbol == \"sBTCUSDT\") | (((.lastEp | tonumber) - (.openEp | tonumber)) / (.openEp | tonumber) * 100)) // 0) as \$btcChange
        | \$spot
        | map(. as \$i | {symbol, lastPx: ((.lastEp | tonumber) / 100000000), changePct: (((.lastEp | tonumber) - (.openEp | tonumber)) / (.openEp | tonumber) * 100), vs_btc_alpha: ((((.lastEp | tonumber) - (.openEp | tonumber)) / (.openEp | tonumber) * 100) - \$btcChange)})
        | sort_by(.vs_btc_alpha)
        | { MARKET_LEADERS_OVER_BTC: (.[-5:] | reverse), MARKET_LAGGARDS_UNDER_BTC: .[0:5] }
      ),
      SIGNAL_TREND: (
        \$res | map(select(.highEp != null and .lowEp != null and (.highEp | tonumber) > (.lowEp | tonumber) and (.openEp | tonumber) > 0))
        | map(. as \$i | {
            symbol,
            lastPx: ((.lastEp | tonumber) / 100000000),
            changePct: (((.lastEp | tonumber) - (.openEp | tonumber)) / (.openEp | tonumber) * 100),
            rangePct: (((.highEp | tonumber) - (.lowEp | tonumber)) / (.lowEp | tonumber) * 100),
            dirEfficiency: ((((.lastEp | tonumber) - (.openEp | tonumber)) / (.openEp | tonumber) * 100) / (((.highEp | tonumber) - (.lowEp | tonumber)) / (.lowEp | tonumber) * 100) * 100)
          })
        | sort_by(.dirEfficiency)
        | { CLEANEST_UPTREND: (.[-5:] | reverse) }
      ),
      SIGNAL_LIQ: (
        \$res | map(select(.bidEp != null and .askEp != null and (.bidEp | tonumber) > 0 and (.askEp | tonumber) > 0))
        | map(. as \$i | {symbol, spreadPct: ((((.askEp | tonumber) - (.bidEp | tonumber)) / (.bidEp | tonumber)) * 100)})
        | sort_by(.spreadPct)
        | { MOST_LIQUID_LOW_SLIPPAGE: .[0:5], LOWEST_LIQUIDITY_HIGH_RISK: (.[-5:] | reverse) }
      ),
      SIGNAL_WICK: (
        \$res | map(select(.highEp != null and .lowEp != null and (.highEp | tonumber) > (.lowEp | tonumber)))
        | map(. as \$i | {
            symbol,
            wickAsymm: ((([(.lastEp | tonumber), (.openEp | tonumber)] | min) - (.lowEp | tonumber)) / ((.highEp | tonumber) - ([(.lastEp | tonumber), (.openEp | tonumber)] | max) + 0.0001))
          })
        | { POTENTIAL_BOTTOM_ABSORPTION: (sort_by(.wickAsymm) | .[-5:] | reverse) }
      )
    }
" "$SPOT_RAW")

PERP_SIGNALS=$(jq -c "
  (.result | if type == \"array\" then map(select(type == \"object\")) else [] end) as \$res
  | (\$res | map(select(.fundingRateRr != null and (.openRp | tonumber) > 0))) as \$perp
  | {
      SIGNAL_FR: (
        \$perp
        | map(. as \$i | {symbol, lastPx: (.lastRp | tonumber), fundingRate: (.fundingRateRr | tonumber * 100), priceChange: (((.lastRp | tonumber) - (.openRp | tonumber)) / (.openRp | tonumber) * 100)})
        | sort_by(.fundingRate)
        | { SHORTS_CROWDED_POTENTIAL_SQUEEZE: .[0:5], LONGS_CROWDED_POTENTIAL_DUMP: (.[-5:] | reverse) }
      ),
      SIGNAL_CROWDING: (
        \$perp
        | map(. as \$i | {
            symbol,
            crowding: ((.fundingRateRr | tonumber) * ((.openInterestRv | tonumber) / (.volumeRq | tonumber | if . == \"0\" or . == 0 then 1 else (. | tonumber) end)))
          })
        | sort_by(.crowding)
        | { MOST_CROWDED_EXHAUSTION: (.[-5:] | reverse) }
      ),
      SIGNAL_OI: (
        \$res | map(select(.volumeRq != \"0\" and .volumeRq != null and .openInterestRv != null and (.volumeRq | tonumber) > $MIN_VOLUME))
        | map(. as \$i | {symbol, oiToVolRatio: ((.openInterestRv | tonumber) / (.volumeRq | tonumber))})
        | sort_by(.oiToVolRatio)
        | { HEAVY_ACCUMULATION_HIGH_OI: (.[-5:] | reverse) }
      )
    }
" "$PERP_RAW")

ok "Signals computed."

# ── Build Watchlist ────────────────────────────────────────────
WATCHLIST=$(jq -c "{
  OVERSOLD:       (.SIGNAL_OB.MOST_OVERSOLD_PROXY[:3]  | map((.symbol | sub(\"^s\"; \"\")) + \" (\$\" + (.lastPx | tostring) + \")\")),
  OVERBOUGHT:     (.SIGNAL_OB.MOST_OVERBOUGHT_PROXY[:3] | map((.symbol | sub(\"^s\"; \"\")) + \" (\$\" + (.lastPx | tostring) + \")\")),
  FUNDING_SQUEEZE:(\$PERP.SIGNAL_FR.SHORTS_CROWDED_POTENTIAL_SQUEEZE[:3] | map((.symbol | sub(\"^s\"; \"\")) + \" (\$\" + (.lastPx | tostring) + \")\"))
}" --argjson PERP "$PERP_SIGNALS" <<< "$SPOT_SIGNALS")

# ── Best Trade Selection ───────────────────────────────────────
info "Selecting best candidate…"
BEST_TRADE_RAW=$(jq -n \
  --argjson spot "$SPOT_SIGNALS" \
  --argjson perp "$PERP_SIGNALS" '
  [ ($spot + $perp)[] | .[] | .[] ]
  | map(select(.symbol != null))
  | map(.score =
      ((.dirEfficiency // 0 | tonumber) * 2.5) +
      ((.vs_btc_alpha  // 0 | tonumber) * 1.5) +
      ((.rangePct      // 0 | tonumber) * 0.5) -
      (if ((.changePct // 0 | tonumber) | if . < 0 then -. else . end) > 25 then (((.changePct // 0 | tonumber) | if . < 0 then -. else . end) - 25) * 3 else 0 end) -
      (if (.rangePct // 0 | tonumber) > 50 then ((.rangePct // 0 | tonumber) - 50) * 2 else 0 end) -
      ((.fundingRate   // 0 | tonumber) * 15)
    )
  | sort_by(.score) | reverse | .[0]
')

BEST_TRADE_AI=$(echo "$BEST_TRADE_RAW" | jq -c '{
  symbol:     (.symbol | sub("^s"; "")),
  price:      ("$" + (.lastPx      | tostring)),
  changePct:  ((.changePct         | tostring) + "%"),
  efficiency: ((.dirEfficiency // 0 | tostring) + "%"),
  alpha:      ((.vs_btc_alpha  // 0 | tostring) + " pts"),
  score:      (.score | round)
}')

SYMBOL=$(echo "$BEST_TRADE_RAW" | jq -r '.symbol // "UNKNOWN"')
ENTRY=$(echo "$BEST_TRADE_RAW" | jq -r '.lastPx // 0')
RANGE=$(echo "$BEST_TRADE_RAW" | jq -r '.rangePct // 3')

# Cap volatility impact for TP/SL levels to prevent nonsensical targets on outliers
CALC_RANGE=$RANGE
if (( $(echo "$RANGE > 20" | bc -l) )); then CALC_RANGE=20; fi

# Dynamic TP/SL based on capped volatility range
TP1=$(normalize_decimal "$(echo "scale=10; $ENTRY * (1 + ($CALC_RANGE * 0.008))" | bc -l)")
TP2=$(normalize_decimal "$(echo "scale=10; $ENTRY * (1 + ($CALC_RANGE * 0.020))" | bc -l)")
TP3=$(normalize_decimal "$(echo "scale=10; $ENTRY * (1 + ($CALC_RANGE * 0.040))" | bc -l)")
SL=$(normalize_decimal  "$(echo "scale=10; $ENTRY * (1 - ($CALC_RANGE * 0.015))" | bc -l)")

# Ensure SL is not negative and at least a reasonable distance (cap at 30% absolute SL)
if (( $(echo "$SL <= 0" | bc -l) )); then
  SL=$(normalize_decimal "$(echo "scale=10; $ENTRY * 0.70" | bc -l)")
fi

# ── Evaluate existing trade state ──────────────────────────────
info "Evaluating trade state…"
TRADE_STATUS="NONE"
if [[ -n "$OPEN_TRADE" && "$OPEN_TRADE" != "null" ]]; then
  t_symbol=$(echo "$OPEN_TRADE" | jq -r '.symbol')
  t_sl=$(echo "$OPEN_TRADE"  | jq -r '.sl')
  t_tp1=$(echo "$OPEN_TRADE" | jq -r '.tp1')
  t_tp2=$(echo "$OPEN_TRADE" | jq -r '.tp2')
  t_tp3=$(echo "$OPEN_TRADE" | jq -r '.tp3')
  t_opened=$(echo "$OPEN_TRADE" | jq -r '.opened // 0')
  
  IS_SPOT=$(jq -r ".result[] | select(type == \"object\" and .symbol==\"$t_symbol\") | has(\"lastEp\")" "$SPOT_RAW" 2>/dev/null | head -1 || echo "false")
  if [[ "$IS_SPOT" == "true" ]]; then
    RAW_EP=$(jq -r ".result[] | select(type == \"object\" and .symbol==\"$t_symbol\") | .lastEp // 0" "$SPOT_RAW" 2>/dev/null | head -1)
    current=$(format_price "$(bc -l <<< "$RAW_EP / 100000000")")
  else
    current=$(jq -r ".result[] | select(type == \"object\" and .symbol==\"$t_symbol\") | .lastRp // 0" "$PERP_RAW" 2>/dev/null | head -1)
  fi

  if [[ -n "$current" && "$current" != "0" ]]; then
    if (( $(echo "$current <= $t_sl" | bc -l) )); then
      TRADE_STATUS="STOP_LOSS"
      # Deduplicate: only log if this specific trade session hasn't been closed in history
      ALREADY=$(jq -s "map(select(.symbol==\"$t_symbol\" and .opened==$t_opened)) | length" "$TRADE_HISTORY_FILE" 2>/dev/null || echo 0)
      if [[ "$ALREADY" == "0" ]]; then
        jq -n --argjson t "$OPEN_TRADE" --arg exit "$current" --arg status "STOP_LOSS" \
          '$t + {exit_price:($exit|tonumber), result:$status, closed_at:now}' >> "$TRADE_HISTORY_FILE"
      fi
      OPEN_TRADE=""
    elif (( $(echo "$current >= $t_tp3" | bc -l) )); then
      TRADE_STATUS="TP3"
      ALREADY=$(jq -s "map(select(.symbol==\"$t_symbol\" and .opened==$t_opened)) | length" "$TRADE_HISTORY_FILE" 2>/dev/null || echo 0)
      if [[ "$ALREADY" == "0" ]]; then
        jq -n --argjson t "$OPEN_TRADE" --arg exit "$current" --arg status "TP3" \
          '$t + {exit_price:($exit|tonumber), result:$status, closed_at:now}' >> "$TRADE_HISTORY_FILE"
      fi
      OPEN_TRADE=""
    elif (( $(echo "$current >= $t_tp2" | bc -l) )); then TRADE_STATUS="TP2"
    elif (( $(echo "$current >= $t_tp1" | bc -l) )); then
      TRADE_STATUS="TP1"
      # Move SL to Entry
      t_entry=$(echo "$OPEN_TRADE" | jq -r '.entry')
      OPEN_TRADE=$(echo "$OPEN_TRADE" | jq -c --arg e "$t_entry" '.sl = ($e|tonumber)')
    else TRADE_STATUS="RUNNING"
    fi
  fi
fi

if [[ -z "$OPEN_TRADE" || "$OPEN_TRADE" == "null" ]]; then
  OPEN_TRADE=$(jq -n \
    --arg s  "$SYMBOL" --arg e  "$ENTRY" --arg t1 "$TP1" --arg t2 "$TP2" --arg t3 "$TP3" --arg sl "$SL" \
    '{symbol:$s, entry:($e|tonumber), tp1:($t1|tonumber), tp2:($t2|tonumber), tp3:($t3|tonumber), sl:($sl|tonumber), opened:now}')
  [[ "$TRADE_STATUS" == "NONE" ]] && TRADE_STATUS="NEW_TRADE"
fi

OPEN_TRADE_AI=$(echo "$OPEN_TRADE" | jq -c '{
  symbol: (.symbol | sub("^s"; "")),
  entry: ("$" + (.entry | tostring)),
  tp1:   ("$" + (.tp1   | tostring)),
  tp2:   ("$" + (.tp2   | tostring)),
  tp3:   ("$" + (.tp3   | tostring)),
  sl:    ("$" + (.sl    | tostring))
}')

STATS_STR=$(jq -rs '
  map(select(.result != null)) |
  (map(select(.result | startswith("TP"))) | length) as $w |
  (map(select(.result == "STOP_LOSS"))      | length) as $l |
  ($w + $l) as $t |
  if $t == 0 then "Record: 0-0 | Win Rate: 0%"
  else "Record: \($w)-\($l) | Win Rate: \((($w * 100 / $t) | round))%"
  end
' "$TRADE_HISTORY_FILE" 2>/dev/null || echo "Record: 0-0 | Win Rate: 0%")

jq -n --argjson open "${OPEN_TRADE:-null}" --arg status "$TRADE_STATUS" \
  '{open_trade:$open, last_status:$status}' > "$STATE_FILE"

# ── Assemble AI payload ─────────────────────────────────────
info "Calling NVIDIA/Nebius ($MODEL) — Full Intelligence Pass…"

CURRENT_DATE=$(date '+%B %d, %Y')
SYSTEM_PROMPT="You are the elite market strategist for The P.L.U.M.B.U.S. (Price Level Updates, Market Briefings, & Universal Signals).
Today's date is ${CURRENT_DATE}. 

DEEP KNOWLEDGE ROLE ENFORCEMENT:
You operate with the expertise of a Tier-1 macro hedge fund analyst. Your analysis must go beyond surface-level price action. 
- Use professional terminology accurately (e.g., 'liquidity gaps', 'funding rate normalization', 'open interest flush', 'volatility compression', 'delta imbalances').
- Explain the 'why' behind signals by connecting spot flows to derivative market positioning (Perp signals).
- Avoid generic retail advice; focus on institutional-grade insight and high-signal data synthesis.
- Maintain a tone that is authoritative, technically precise, and commercially sharp.

IMPORTANT: This is the INAUGURAL TRANSMISSION. Explicitly welcome the audience to this first-ever official session of The P.L.U.M.B.U.S. and mention today's date (${CURRENT_DATE}) in your analysis.
Review all provided inputs and synthesize them into a structured JSON briefing that draws from every available data source: scoreboard, active trade state, best candidate, watchlist, spot/perp signal sets, and prior session context.

NOTE: The Scoreboard (Record/Win Rate) is already displayed in a separate section. Do NOT include it in your analysis, headline, or briefing_raw.

Required JSON keys:
- headline: Punchy single-line session summary (max 100 chars).
- analysis: Detailed paragraph synthesizing the signal narrative and trade context (max 800 chars).
- trade_rationale: Concise rationale for the best candidate (max 150 chars).
- position_tracking: A readable text update for the ACTIVE TRADE (Entry, TP1, TP2, TP3, SL). Do NOT use JSON format. Example: \"Entry: \$0.14 | TP1: \$0.15 | Stop: \$0.13\".
- watchlist: Clean multi-line grouped list: \"📍 OVERSOLD:\n• TICKER (\$price)\n📍 OVERBOUGHT:\n• ...\n📍 FUNDING SQUEEZE:\n• ...\"
- outlook: Strategic forward-looking teaser (max 250 chars).
- setups: Array of exactly 3 setup strings for WATCHLIST assets (max 150 chars each).
- sentiment_score: An integer from 0 (Extreme Fear) to 100 (Extreme Greed) representing the market mood.
- briefing_raw: A conversational, Bloomberg-style paragraph addressing \"the desk\". Use clean ticker names (e.g., BTCUSDT, not sBTCUSDT). Start with a punchy hook. No bullet points. (max 1200 chars)."

USER_CONTENT="SCOREBOARD: $STATS_STR
TRADE STATUS: $TRADE_STATUS
ACTIVE TRADE: $OPEN_TRADE_AI
BEST CANDIDATE: $BEST_TRADE_AI
WATCHLIST: $WATCHLIST
SPOT SIGNALS: $SPOT_SIGNALS
PERP SIGNALS: $PERP_SIGNALS
PREVIOUS REPORT: ${PREV_BRIEF:-Opening transmission.}

Return the dual-mode JSON briefing with strong desk personality and an explicit tie to the previous report."

PAYLOAD=$(jq -n \
  --arg model "$MODEL" --arg temp "$TEMPERATURE" --argjson max "$MAX_TOKENS" \
  --arg sys "$SYSTEM_PROMPT" --arg data "$USER_CONTENT" \
  '{model:$model, temperature:($temp|tonumber), max_tokens:$max,
    response_format:{type:"json_object"},
    messages:[{role:"system",content:$sys},{role:"user",content:$data}]}')

# ── AI Call ────────────────────────────────────────────────────
log "Making NVIDIA API call..."
RESPONSE=""
attempt=1; delay="$RETRY_DELAY"
err_file="./data/nvidia_api_error.txt"

while (( attempt <= RETRY_MAX )); do
  log "NVIDIA API call (attempt $attempt/$RETRY_MAX)..."

  # Capture response and curl exit code
  if RESPONSE=$(curl -sfL -X POST "$NVIDIA_URL" \
    --max-time "$NVIDIA_TIMEOUT" \
    -H "Authorization: Bearer $NVIDIA_KEY" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>"$err_file"); then

    # Check if response contains an error
    if echo "$RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
      api_error=$(echo "$RESPONSE" | jq -r '.error.message // .error // "Unknown error"')
      warn "NVIDIA API error: $api_error (attempt $attempt/$RETRY_MAX)"
      log_event "WARN" "NVIDIA API error: $api_error"
    else
      ok "NVIDIA API response received"
      break
    fi
  else
    curl_exit=$?
    err_msg=$(cat "$err_file" 2>/dev/null | tr '\n' ' ' || echo "Unknown error")

    case $curl_exit in
      28) warn "NVIDIA API timeout (attempt $attempt/$RETRY_MAX)" ;;
      35) warn "NVIDIA SSL error (attempt $attempt/$RETRY_MAX)" ;;
      *)  warn "NVIDIA API call failed with exit code $curl_exit (attempt $attempt/$RETRY_MAX)" ;;
    esac
    log_event "WARN" "NVIDIA API failed: exit=$curl_exit, error=$err_msg"
  fi

  (( attempt++ ))
  if [[ $attempt -le $RETRY_MAX ]]; then 
    sleep "$delay"
    delay=$(( delay * 2 ))
  fi
done

[[ -z "$RESPONSE" ]] && log_event "ERROR" "NVIDIA API failed after $RETRY_MAX attempts"
JSON_OUT=$(jq -r '.choices[0].message.content // empty' <<<"$RESPONSE")
[[ -z "$JSON_OUT" ]] && log_event "ERROR" "AI returned empty content"

# ── Save summary ──────────────────────────────────────────────
HEADLINE=$(echo "$JSON_OUT" | jq -r '.headline')
OUTLOOK=$(echo "$JSON_OUT"  | jq -r '.outlook')
echo "$HEADLINE: $OUTLOOK" | cut -c1-200 > "$PREV_BRIEF_FILE"

# ── Telegram Output ────────────────────────────────────────────
if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
  info "Broadcasting Transmission..."
  html_escape() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }
  TIME_STAMP=$(date '+%Y-%m-%d | %H:%M %Z')
  BEST_TICKER=$(echo "$BEST_TRADE_RAW" | jq -r '.symbol' | sed 's/^s//')
  BEST_PRICE=$(format_price "$(echo "$BEST_TRADE_RAW" | jq -r '.lastPx')")
  BEST_SURGE=$(echo "$BEST_TRADE_RAW" | jq -r '.changePct // 0' | xargs printf "%.2f%%")
  SENTIMENT_SCORE=$(echo "$JSON_OUT" | jq -r '.sentiment_score // 50')

  # Generate Visual (Gauge)
  GAUGE_COLOR="green"
  [[ $SENTIMENT_SCORE -lt 40 ]] && GAUGE_COLOR="red"
  [[ $SENTIMENT_SCORE -lt 60 && $SENTIMENT_SCORE -ge 40 ]] && GAUGE_COLOR="orange"

  CHART_CONFIG="{type:'gauge',data:{datasets:[{value:$SENTIMENT_SCORE,data:[$SENTIMENT_SCORE],backgroundColor:'$GAUGE_COLOR'}]},options:{title:{display:true,text:'MARKET SENTIMENT INDEX',fontColor:'white',fontSize:20},needle:{enabled:true,color:'white'},valueLabel:{display:true,formatter:(v)=>v+'%',fontColor:'white',fontSize:30},chartArea:{backgroundColor:'black'}}}"
  GAUGE_FILE="./data/sentiment_gauge.png"
  # URL encode only the config part
  CONF_ENC=$(python3 -c "import urllib.parse; print(urllib.parse.quote(\"\"\"$CHART_CONFIG\"\"\"))")
  curl -s -o "$GAUGE_FILE" "https://quickchart.io/chart?c=$CONF_ENC"

  ANALYSIS_ESC=$(html_escape "$(echo "$JSON_OUT" | jq -r '.analysis')")
  POS_TRACK_ESC=$(html_escape "$(echo "$JSON_OUT" | jq -r '.position_tracking')")
  WATCHLIST_ESC=$(html_escape "$(echo "$JSON_OUT" | jq -r '.watchlist')")
  OUTLOOK_ESC=$(html_escape "$OUTLOOK")
  HEADLINE_ESC=$(html_escape "$HEADLINE")
  STATS_ESC=$(html_escape "$STATS_STR")
  TRADE_RATIONALE=$(echo "$JSON_OUT" | jq -r '.trade_rationale // empty')
  TRADE_RATIONALE_ESC=$(html_escape "$TRADE_RATIONALE")
  
  if [[ -n "$TRADE_RATIONALE_ESC" ]]; then
    TRADE_RATIONALE_SECTION="🎯 <b>TRADE RATIONALE</b>
<blockquote>${TRADE_RATIONALE_ESC}</blockquote>

"
  else
    TRADE_RATIONALE_SECTION=""
  fi
  SETUPS_HTML=$(echo "$JSON_OUT" | jq -r '.setups[]' | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' | sed 's/^/• /')
  BLOOMBERG_OUT=$(echo "$JSON_OUT" | jq -r '.briefing_raw')
  BLOOMBERG_CLEAN=$(echo "$BLOOMBERG_OUT" | sed 's/\*\*\([^*]*\)\*\*/<b>\1<\/b>/g' | sed -E 's/\bs([A-Z0-9]+USDT)\b/<code>\1<\/code>/g')

  DISCLAIMER="<i>Educational market commentary only. Not financial advice.</i>"

  FINAL_MSG="📡 <b>THE P.L.U.M.B.U.S. TRANSMISSION</b>
📅 <code>${TIME_STAMP}</code>

📈 <b>SCOREBOARD</b>
<pre>${STATS_ESC}</pre>

<b>SESSION HEADLINE</b>
<blockquote>${HEADLINE_ESC}</blockquote>

📊 <b>DESK ANALYSIS</b>
${ANALYSIS_ESC}

${TRADE_RATIONALE_SECTION}🚀 <b>BEST NEW CANDIDATE</b>
• <b>Ticker:</b> <code>${BEST_TICKER}</code>
• <b>Price:</b> <code>\$${BEST_PRICE}</code>
• <b>24h Surge:</b> <code>${BEST_SURGE}</code>

🎯 <b>ACTIVE TRADE TRACKING</b>
<blockquote>${POS_TRACK_ESC}</blockquote>

🔍 <b>ON RADAR</b>
<pre>${WATCHLIST_ESC}</pre>

🔭 <b>FORWARD OUTLOOK</b>
${OUTLOOK_ESC}

⚡ <b>HIGH-CONVICTION SETUPS</b>
${SETUPS_HTML}

_________________________________
${DISCLAIMER}"

  RAW_MSG="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

${BLOOMBERG_CLEAN}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Send Telegram messages with error handling
  log "Sending Telegram transmission..."

  tg_attempt=1 tg_delay="$RETRY_DELAY" tg_err="./data/tg_error.txt"

  # Send Gauge Photo
  if [[ -f "$GAUGE_FILE" ]]; then
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendPhoto" \
      -F chat_id="$TELEGRAM_CHAT_ID" -F photo="@$GAUGE_FILE" > /dev/null
  fi

  # Send FINAL_MSG
  while (( tg_attempt <= RETRY_MAX )); do
    if TG_RESP=$(curl -s --max-time "$TELEGRAM_TIMEOUT" "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
      -d chat_id="$TELEGRAM_CHAT_ID" -d parse_mode="HTML" --data-urlencode "text=$FINAL_MSG" 2>"$tg_err"); then
      if echo "$TG_RESP" | jq -e '.ok == true' >/dev/null 2>&1; then
        ok "Telegram message 1 sent"
        break
      else
        tg_error=$(echo "$TG_RESP" | jq -r '.description // "Unknown error"')
        warn "Telegram error: $tg_error (attempt $tg_attempt/$RETRY_MAX)"
        log_event "WARN" "Telegram message 1 failed: $tg_error"
      fi
    else
      warn "Telegram API call failed (attempt $tg_attempt/$RETRY_MAX)"
    fi
    (( tg_attempt++ ))
    if [[ $tg_attempt -le $RETRY_MAX ]]; then sleep "$tg_delay"; tg_delay=$(( tg_delay * 2 )); fi
  done
  
  # Send RAW_MSG
  tg_attempt=1 tg_delay="$RETRY_DELAY"
  while (( tg_attempt <= RETRY_MAX )); do
    if TG_RESP=$(curl -s --max-time "$TELEGRAM_TIMEOUT" "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
      -d chat_id="$TELEGRAM_CHAT_ID" -d parse_mode="HTML" --data-urlencode "text=$RAW_MSG" 2>"$tg_err"); then
      if echo "$TG_RESP" | jq -e '.ok == true' >/dev/null 2>&1; then
        ok "Telegram message 2 sent"
        break
      else
        tg_error=$(echo "$TG_RESP" | jq -r '.description // "Unknown error"')
        warn "Telegram error: $tg_error (attempt $tg_attempt/$RETRY_MAX)"
        log_event "WARN" "Telegram message 2 failed: $tg_error"
      fi
    else
      warn "Telegram API call failed (attempt $tg_attempt/$RETRY_MAX)"
    fi
    (( tg_attempt++ ))
    if [[ $tg_attempt -le $RETRY_MAX ]]; then sleep "$tg_delay"; tg_delay=$(( tg_delay * 2 )); fi
  done
  
  ok "Transmission complete."
fi

log "Tokens: $(jq -r '.usage.total_tokens // "?"' <<<"$RESPONSE")"
