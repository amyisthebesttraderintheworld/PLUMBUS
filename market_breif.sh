#!/bin/bash
# ============================================================
#  The P.L.U.M.B.U.S.
#  (Price Level Updates, Market Briefings, & Universal Signals)
# ============================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────
ENV_FILE="${ENV_FILE:-.env}"
STATE_FILE="${STATE_FILE:-./trade_state.json}"
TRADE_HISTORY_FILE="${TRADE_HISTORY_FILE:-./trade_history.json}"
MODEL="${NVIDIA_MODEL:-meta-llama/Llama-3.3-70B-Instruct}"
TEMPERATURE="${NVIDIA_TEMPERATURE:-0.6}"
MAX_TOKENS="${NVIDIA_MAX_TOKENS:-4096}"
MIN_VOLUME="${MIN_VOLUME:-10000}"
SAVE_REPORT="${SAVE_REPORT:-false}"
REPORT_DIR="${REPORT_DIR:-./reports}"
RETRY_MAX=3
RETRY_DELAY=2
PHEMEX_SPOT="https://api.phemex.com/md/spot/ticker/24hr/all"
PHEMEX_PERP="https://api.phemex.com/md/v3/ticker/24hr/all"
NVIDIA_URL="https://api.studio.nebius.ai/v1/chat/completions"
TMPDIR_LOCAL=$(mktemp -d)
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT INT TERM

PREV_BRIEF_FILE="${PREV_BRIEF_FILE:-./last_brief.txt}"
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
  while (( attempt <= RETRY_MAX )); do
    if curl -sfL --max-time 15 "$url" -o "$out" 2>/dev/null; then
      if jq -e '.result | type == "array"' "$out" >/dev/null 2>&1; then return 0; fi
      warn "$label returned invalid JSON structure (attempt $attempt/$RETRY_MAX)"
    else
      warn "$label fetch failed (attempt $attempt/$RETRY_MAX)"
    fi
    (( attempt++ ))
    [[ $attempt -le $RETRY_MAX ]] && sleep "$delay"
    delay=$(( delay * 2 ))
  done
  echo "FAILED" > "$out.status"
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
  .result as \$res
  | (\$res | map(select(.openEp != null and .openEp > 0))) as \$spot
  | {
      SIGNAL_OB: (
        \$spot
        | map({symbol, changePct: (((.lastEp - .openEp) / .openEp) * 100), lastPx: (.lastEp / 100000000)})
        | sort_by(.changePct)
        | { MOST_OVERSOLD_PROXY: .[0:5], MOST_OVERBOUGHT_PROXY: (.[-5:] | reverse) }
      ),
      SIGNAL_VOL: (
        \$res | map(select(.lowEp > 0 and .highEp > .lowEp))
        | map({symbol, lastPx: (.lastEp / 100000000), rangePct: (((.highEp - .lowEp) / .lowEp) * 100)})
        | sort_by(.rangePct)
        | { MAX_INTRADAY_VOLATILITY: (.[-10:] | reverse) }
      ),
      SIGNAL_ALPHA: (
        ((\$res | .[] | select(.symbol == \"sBTCUSDT\") | ((.lastEp - .openEp) / .openEp * 100)) // 0) as \$btcChange
        | \$spot
        | map({symbol, lastPx: (.lastEp / 100000000), changePct: ((.lastEp - .openEp) / .openEp * 100), vs_btc_alpha: (((.lastEp - .openEp) / .openEp * 100) - \$btcChange)})
        | sort_by(.vs_btc_alpha)
        | { MARKET_LEADERS_OVER_BTC: (.[-5:] | reverse), MARKET_LAGGARDS_UNDER_BTC: .[0:5] }
      ),
      SIGNAL_TREND: (
        \$res | map(select(.highEp > .lowEp and .openEp > 0))
        | map({
            symbol,
            lastPx: (.lastEp / 100000000),
            changePct: ((.lastEp - .openEp) / .openEp * 100),
            rangePct: ((.highEp - .lowEp) / .lowEp * 100),
            dirEfficiency: (((.lastEp - .openEp) / .openEp * 100) / ((.highEp - .lowEp) / .lowEp * 100) * 100)
          })
        | sort_by(.dirEfficiency)
        | { CLEANEST_UPTREND: (.[-5:] | reverse) }
      ),
      SIGNAL_WICK: (
        \$res | map(select(.highEp > .lowEp))
        | map({
            symbol,
            upperWick: ((.highEp - ([.lastEp, .openEp] | max)) / (.highEp - .lowEp) * 100),
            lowerWick: ((([.lastEp, .openEp] | min) - .lowEp) / (.highEp - .lowEp) * 100)
          })
        | { POTENTIAL_TOP_REJECTION: (sort_by(.upperWick) | .[-5:] | reverse), POTENTIAL_BOTTOM_ABSORPTION: (sort_by(.lowerWick) | .[-5:] | reverse) }
      )
    }
" "$SPOT_RAW")

PERP_SIGNALS=$(jq -c "
  .result as \$res
  | (\$res | map(select(.fundingRateRr != null and (.openRp | tonumber) > 0))) as \$perp
  | {
      SIGNAL_FR: (
        \$perp
        | map({symbol, lastPx: (.lastRp | tonumber), fundingRate: (.fundingRateRr | tonumber * 100), changePct: (((.lastRp | tonumber) - (.openRp | tonumber)) / (.openRp | tonumber) * 100)})
        | sort_by(.fundingRate)
        | { SHORTS_CROWDED_POTENTIAL_SQUEEZE: .[0:5], LONGS_CROWDED_POTENTIAL_DUMP: (.[-5:] | reverse) }
      ),
      SIGNAL_OI: (
        \$res | map(select(.volumeRq != \"0\" and .volumeRq != null and .openInterestRv != null and (.volumeRq | tonumber) > $MIN_VOLUME))
        | map({symbol, oiToVolRatio: ((.openInterestRv | tonumber) / (.volumeRq | tonumber))})
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
      (if (.changePct // 0 | tonumber) > 25 then ((.changePct // 0 | tonumber) - 25) * 3 else 0 end) -
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

# Dynamic TP/SL based on 24h volatility range
TP1=$(normalize_decimal "$(echo "scale=10; $ENTRY * (1 + ($RANGE * 0.008))" | bc -l)")
TP2=$(normalize_decimal "$(echo "scale=10; $ENTRY * (1 + ($RANGE * 0.020))" | bc -l)")
TP3=$(normalize_decimal "$(echo "scale=10; $ENTRY * (1 + ($RANGE * 0.040))" | bc -l)")
SL=$(normalize_decimal  "$(echo "scale=10; $ENTRY * (1 - ($RANGE * 0.015))" | bc -l)")

# ── Evaluate existing trade state ──────────────────────────────
info "Evaluating trade state…"
TRADE_STATUS="NONE"
if [[ -n "$OPEN_TRADE" && "$OPEN_TRADE" != "null" ]]; then
  t_symbol=$(echo "$OPEN_TRADE" | jq -r '.symbol')
  t_sl=$(echo "$OPEN_TRADE"  | jq -r '.sl')
  t_tp3=$(echo "$OPEN_TRADE" | jq -r '.tp3')
  t_opened=$(echo "$OPEN_TRADE" | jq -r '.opened // 0')
  
  IS_SPOT=$(jq -r ".result[] | select(.symbol==\"$t_symbol\") | has(\"lastEp\")" "$SPOT_RAW" 2>/dev/null | head -1 || echo "false")
  if [[ "$IS_SPOT" == "true" ]]; then
    RAW_EP=$(jq -r ".result[] | select(.symbol==\"$t_symbol\") | .lastEp // 0" "$SPOT_RAW" 2>/dev/null | head -1)
    current=$(normalize_decimal "$(echo "scale=10; $RAW_EP / 100000000" | bc -l)")
  else
    current=$(jq -r ".result[] | select(.symbol==\"$t_symbol\") | .lastRp // 0" "$PERP_RAW" 2>/dev/null | head -1)
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

STATS_STR=$(jq -s '
  map(select(.result != null)) |
  (map(select(.result | startswith("TP"))) | length) as $w |
  (map(select(.result == "STOP_LOSS"))      | length) as $l |
  ($w + $l) as $t |
  if $t == 0 then "0 Wins - 0 Losses (0%)"
  else "\($w) Wins - \($l) Losses (\(($w * 100 / $t) | round)%)"
  end
' "$TRADE_HISTORY_FILE" 2>/dev/null || echo "0 Wins - 0 Losses (0%)")

jq -n --argjson open "${OPEN_TRADE:-null}" --arg status "$TRADE_STATUS" \
  '{open_trade:$open, last_status:$status}' > "$STATE_FILE"

# ── Assemble AI payload ─────────────────────────────────────
info "Calling NVIDIA/Nebius ($MODEL) — Full Intelligence Pass…"

SYSTEM_PROMPT='You are the lead analyst for The P.L.U.M.B.U.S. (Price Level Updates, Market Briefings, & Universal Signals).
Synthesize the provided data into a structured JSON briefing containing two distinct versions of the report.

Required JSON keys:
- headline: Punchy single-line session summary (max 100 chars).
- analysis: Detailed paragraph synthesizing the signal narrative (max 500 chars).
- position_tracking: Active trade update (entry, tp1, tp2, tp3, sl).
- watchlist: Clean multi-line grouped list: "📍 OVERSOLD:\n• TICKER ($price)\n📍 OVERBOUGHT:\n• ...\n📍 FUNDING SQUEEZE:\n• ..."
- outlook: Strategic forward-looking teaser (max 250 chars).
- setups: Array of exactly 3 setup strings for WATCHLIST assets (max 150 chars each).
- briefing_raw: A conversational, Bloomberg-style paragraph (Bloomberg style) addressing "the desk". You MUST use clean ticker names (e.g., BTCUSDT, not sBTCUSDT). Start with a punchy hook. (max 1000 chars). No bullet points.'

USER_CONTENT="SCOREBOARD: $STATS_STR
TRADE STATUS: $TRADE_STATUS
ACTIVE TRADE: $OPEN_TRADE_AI
BEST CANDIDATE: $BEST_TRADE_AI
WATCHLIST: $WATCHLIST
SIGNALS: ${SPOT_SIGNALS} ${PERP_SIGNALS}
PREVIOUS SESSION: ${PREV_BRIEF:-Opening transmission.}

Return the dual-mode JSON briefing."

PAYLOAD=$(jq -n \
  --arg model "$MODEL" --arg temp "$TEMPERATURE" --argjson max "$MAX_TOKENS" \
  --arg sys "$SYSTEM_PROMPT" --arg data "$USER_CONTENT" \
  '{model:$model, temperature:($temp|tonumber), max_tokens:$max,
    response_format:{type:"json_object"},
    messages:[{role:"system",content:$sys},{role:"user",content:$data}]}')

# ── AI Call ────────────────────────────────────────────────────
RESPONSE=""
attempt=1; delay="$RETRY_DELAY"
while (( attempt <= RETRY_MAX )); do
  RESPONSE=$(curl -sfL -X POST "$NVIDIA_URL" \
    -H "Authorization: Bearer $NVIDIA_KEY" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>/dev/null) && break
  (( attempt++ )); sleep "$delay"; delay=$(( delay * 2 ))
done

[[ -z "$RESPONSE" ]] && die "API did not respond."
JSON_OUT=$(jq -r '.choices[0].message.content // empty' <<<"$RESPONSE")
[[ -z "$JSON_OUT" ]] && die "AI returned empty content."

# ── Save summary ──────────────────────────────────────────────
HEADLINE=$(echo "$JSON_OUT" | jq -r '.headline')
OUTLOOK=$(echo "$JSON_OUT"  | jq -r '.outlook')
echo "$HEADLINE: $OUTLOOK" | cut -c1-200 > "$PREV_BRIEF_FILE"

# ── Telegram Output ────────────────────────────────────────────
if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
  info "Broadcasting Transmission..."
  esc() { echo "$1" | sed 's/</\&lt;/g; s/>/\&gt;/g'; }
  TIME_STAMP=$(date '+%Y-%m-%d | %H:%M %Z')
  BEST_TICKER=$(echo "$BEST_TRADE_RAW" | jq -r '.symbol' | sed 's/^s//')
  BEST_PRICE=$(format_price "$(echo "$BEST_TRADE_RAW" | jq -r '.lastPx')")
  BEST_SURGE=$(echo "$BEST_TRADE_RAW" | jq -r '.changePct // 0' | xargs printf "%.2f%%")

  ANALYSIS_ESC=$(esc "$(echo "$JSON_OUT" | jq -r '.analysis')")
  POS_TRACK_ESC=$(esc "$(echo "$JSON_OUT" | jq -r '.position_tracking')")
  WATCHLIST_ESC=$(esc "$(echo "$JSON_OUT" | jq -r '.watchlist')")
  OUTLOOK_ESC=$(esc "$OUTLOOK")
  HEADLINE_ESC=$(esc "$HEADLINE")
  SETUPS_HTML=$(echo "$JSON_OUT" | jq -r '.setups[]' | sed 's/</\&lt;/g; s/>/\&gt;/g' | sed 's/^/• /')
  BLOOMBERG_OUT=$(echo "$JSON_OUT" | jq -r '.briefing_raw')
  BLOOMBERG_CLEAN=$(echo "$BLOOMBERG_OUT" | sed 's/\*\*\([^*]*\)\*\*/<b>\1<\/b>/g' | sed -E 's/\bs([A-Z0-9]+USDT)\b/<code>\1<\/code>/g')

  FINAL_MSG="📡 <b>THE P.L.U.M.B.U.S. TRANSMISSION</b>
📅 <code>${TIME_STAMP}</code>

📈 <b>SCOREBOARD</b>
<blockquote>${STATS_STR}</blockquote>

<b>SESSION HEADLINE</b>
<blockquote>${HEADLINE_ESC}</blockquote>

📊 <b>DESK ANALYSIS</b>
${ANALYSIS_ESC}

🚀 <b>BEST CANDIDATE</b>
• <b>Ticker:</b> <code>${BEST_TICKER}</code>
• <b>Price:</b> <code>\$${BEST_PRICE}</code>
• <b>24h Surge:</b> <code>${BEST_SURGE}</code>

🎯 <b>POSITION TRACKING</b>
${POS_TRACK_ESC}

🔍 <b>ON RADAR</b>
${WATCHLIST_ESC}

🔭 <b>FORWARD OUTLOOK</b>
${OUTLOOK_ESC}

⚡ <b>HIGH-CONVICTION SETUPS</b>
${SETUPS_HTML}"

  RAW_MSG="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

${BLOOMBERG_CLEAN}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" -d parse_mode="HTML" --data-urlencode "text=$FINAL_MSG" >/dev/null
  curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" -d parse_mode="HTML" --data-urlencode "text=$RAW_MSG" >/dev/null
  ok "Transmission complete."
fi

log "Tokens: $(jq -r '.usage.total_tokens // "?"' <<<"$RESPONSE")"
