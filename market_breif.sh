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
TRADE_TIMEOUT_HOURS="${TRADE_TIMEOUT_HOURS:-24}"
MODEL="${NVIDIA_MODEL:-meta-llama/Llama-3.3-70B-Instruct}"
TEMPERATURE="${NVIDIA_TEMPERATURE:-0.5}"
MAX_TOKENS="${NVIDIA_MAX_TOKENS:-8192}"
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

# Normalize a decimal string that may have a leading dot (bc -l output)
normalize_decimal() {
  echo "$1" | sed 's/^\./0./; s/^-\./-0./'
}

# Format a pre-scaled decimal for display (4 sig decimal places, no trailing zeros)
format_price() {
  local p="$1"
  if [[ -z "$p" || "$p" == "0" ]]; then echo "0.00"; return; fi
  printf "%.8f" "$p" | sed 's/0*$//; s/\.$//'
}

# ── Preflight checks ──────────────────────────────────────────
# Source .env if it exists (local dev), but don't fail if missing (CI/Actions)
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
[[ -n "${NVIDIA_KEY:-}" ]] || die "NVIDIA_KEY is not set. Set it in $ENV_FILE or as an environment variable."
command -v jq   &>/dev/null || die "jq is required but not installed."
command -v curl &>/dev/null || die "curl is required but not installed."
command -v bc   &>/dev/null || die "bc is required but not installed."

# ── Retry-aware curl wrapper ───────────────────────────────────
fetch() {
  local url="$1" out="$2" label="${3:-Data}" attempt=1 delay="$RETRY_DELAY"
  while (( attempt <= RETRY_MAX )); do
    if curl -sfL --max-time 15 "$url" -o "$out" 2>/dev/null; then
      if jq -e '.result | type == "array"' "$out" >/dev/null 2>&1; then
        return 0
      fi
      warn "$label returned invalid structure (attempt $attempt/$RETRY_MAX)"
    else
      warn "$label fetch failed (attempt $attempt/$RETRY_MAX)"
    fi
    (( attempt++ ))
    if (( attempt <= RETRY_MAX )); then
      log "Retrying in ${delay}s…"
      sleep "$delay"
      delay=$(( delay * 2 ))
    fi
  done
  echo "FAILED" > "$out.status"
  return 1
}

# ── Load trade state ──────────────────────────────────────────
if [[ -f "$STATE_FILE" ]]; then
  TRADE_STATE=$(cat "$STATE_FILE")
else
  TRADE_STATE='{}'
fi

OPEN_TRADE=$(echo "$TRADE_STATE" | jq -c '.open_trade // empty')

# ── Migrate old raw-integer format → decimal ──────────────────
# Old scripts stored raw Phemex integers (e.g. 14260000).
# New scripts store pre-scaled decimals (e.g. 0.1426).
# Detect by checking if entry > 1000, which no real crypto price ever is.
if [[ -n "$OPEN_TRADE" && "$OPEN_TRADE" != "null" ]]; then
  ENTRY_CHECK=$(echo "$OPEN_TRADE" | jq -r '.entry | tonumber')
  if (( $(echo "$ENTRY_CHECK > 1000" | bc -l) )); then
    warn "Old raw-integer trade state detected — migrating to decimal format…"
    OPEN_TRADE=$(echo "$OPEN_TRADE" | jq -c '{
      symbol,
      entry: ((.entry | tonumber) / 100000000),
      tp1:   ((.tp1   | tonumber) / 100000000),
      tp2:   ((.tp2   | tonumber) / 100000000),
      tp3:   ((.tp3   | tonumber) / 100000000),
      sl:    ((.sl    | tonumber) / 100000000),
      opened
    }')
    ok "Migration complete."
  fi
fi

# ── Load trade history (last 10, NDJSON format) ───────────────
# FIX: jq -s '.[-10:]' — never pipe a JSON array through tail
if [[ -f "$TRADE_HISTORY_FILE" ]]; then
  TRADE_HISTORY=$(jq -s '.[-10:]' "$TRADE_HISTORY_FILE" 2>/dev/null || echo '[]')
else
  TRADE_HISTORY='[]'
fi

# ── Parallel data fetch ────────────────────────────────────────
echo -e "\n${BOLD}  The P.L.U.M.B.U.S.${RESET}  ${DIM}$(date '+%Y-%m-%d %H:%M:%S %Z')${RESET}"
echo -e "${DIM}  Price Level Updates, Market Briefings, & Universal Signals${RESET}\n"
info "Fetching market data in parallel…"

SPOT_RAW="$TMPDIR_LOCAL/spot.json"
PERP_RAW="$TMPDIR_LOCAL/perp.json"

fetch "$PHEMEX_SPOT" "$SPOT_RAW" "Spot" &
fetch "$PHEMEX_PERP" "$PERP_RAW" "Perp" &
wait

[[ -f "$SPOT_RAW.status" || -f "$PERP_RAW.status" ]] && die "One or more data fetches failed."
ok "Raw data fetched and validated."

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
      )
    }
" "$PERP_RAW")

ok "All signals computed."

# ── Build Watchlist ────────────────────────────────────────────
WATCHLIST=$(jq -c "{
  OVERSOLD:       (.SIGNAL_OB.MOST_OVERSOLD_PROXY[:3]  | map((.symbol | sub(\"^s\"; \"\")) + \" (\$\" + (.lastPx | tostring) + \")\")),
  OVERBOUGHT:     (.SIGNAL_OB.MOST_OVERBOUGHT_PROXY[:3] | map((.symbol | sub(\"^s\"; \"\")) + \" (\$\" + (.lastPx | tostring) + \")\")),
  FUNDING_SQUEEZE:(\$PERP.SIGNAL_FR.SHORTS_CROWDED_POTENTIAL_SQUEEZE[:3] | map((.symbol | sub(\"^s\"; \"\")) + \" (\$\" + (.lastPx | tostring) + \")\"))
}" --argjson PERP "$PERP_SIGNALS" <<< "$SPOT_SIGNALS")

# ── Best Trade Selection ───────────────────────────────────────
info "Selecting best trade candidate…"

BEST_TRADE_RAW=$(jq -n \
  --argjson spot "$SPOT_SIGNALS" \
  --argjson perp "$PERP_SIGNALS" '
  [ ($spot + $perp)[] | .[] | .[] ]
  | map(select(.symbol != null))
  | map(.score =
      ((.dirEfficiency // 0) * 2.5) +
      ((.vs_btc_alpha  // 0) * 1.5) +
      ((.rangePct      // 0) * 0.5) -
      (if (.changePct // 0) > 25 then ((.changePct // 0) - 25) * 3 else 0 end) -
      ((.fundingRate   // 0) * 15)
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

# FIX: Dynamic TP/SL based on volatility
RANGE=$(echo "$BEST_TRADE_RAW" | jq -r '.rangePct // 3')
TP1=$(normalize_decimal "$(echo "scale=8; $ENTRY * (1 + ($RANGE * 0.008))" | bc -l)")
TP2=$(normalize_decimal "$(echo "scale=8; $ENTRY * (1 + ($RANGE * 0.020))" | bc -l)")
TP3=$(normalize_decimal "$(echo "scale=8; $ENTRY * (1 + ($RANGE * 0.040))" | bc -l)")
SL=$(normalize_decimal  "$(echo "scale=8;  $ENTRY * (1 - ($RANGE * 0.015))" | bc -l)")

# ── Evaluate existing trade state ──────────────────────────────
info "Evaluating existing trade state…"
TRADE_STATUS="NONE"

if [[ -n "$OPEN_TRADE" && "$OPEN_TRADE" != "null" ]]; then
  t_symbol=$(echo "$OPEN_TRADE" | jq -r '.symbol')
  t_sl=$(echo "$OPEN_TRADE"  | jq -r '.sl')
  t_tp1=$(echo "$OPEN_TRADE" | jq -r '.tp1')
  t_tp2=$(echo "$OPEN_TRADE" | jq -r '.tp2')
  t_tp3=$(echo "$OPEN_TRADE" | jq -r '.tp3')

  # Fetch current price, normalizing spot (raw int / 1e8) vs perp (decimal string)
  IS_SPOT=$(jq -r ".result[] | select(.symbol==\"$t_symbol\") | has(\"lastEp\")" "$SPOT_RAW" 2>/dev/null | head -1 || echo "false")
  if [[ "$IS_SPOT" == "true" ]]; then
    RAW_EP=$(jq -r ".result[] | select(.symbol==\"$t_symbol\") | .lastEp // 0" "$SPOT_RAW" 2>/dev/null | head -1)
    current=$(normalize_decimal "$(echo "scale=8; $RAW_EP / 100000000" | bc -l)")
  else
    current=$(jq -r ".result[] | select(.symbol==\"$t_symbol\") | .lastRp // 0" "$PERP_RAW" 2>/dev/null | head -1)
  fi

  if [[ -n "$current" && "$current" != "0" ]]; then
    if (( $(echo "$current <= $t_sl" | bc -l) )); then
      TRADE_STATUS="STOP_LOSS"
      # Dedup: only append if this trade hasn't already been logged with this result
      ALREADY=$(jq -s "map(select(.symbol==\"$t_symbol\" and .result==\"STOP_LOSS\")) | length" "$TRADE_HISTORY_FILE" 2>/dev/null || echo 0)
      if [[ "$ALREADY" == "0" ]]; then
        jq -n --argjson t "$OPEN_TRADE" --arg exit "$current" --arg status "STOP_LOSS" \
          '$t + {exit_price:($exit|tonumber), result:$status, closed_at:now}' >> "$TRADE_HISTORY_FILE"
      fi
      OPEN_TRADE=""
    elif (( $(echo "$current >= $t_tp3" | bc -l) )); then
      TRADE_STATUS="TP3"
      jq -n --argjson t "$OPEN_TRADE" --arg exit "$current" --arg status "TP3" \
        '$t + {exit_price:($exit|tonumber), result:$status, closed_at:now}' >> "$TRADE_HISTORY_FILE"
      OPEN_TRADE=""
    elif (( $(echo "$current >= $t_tp2" | bc -l) )); then TRADE_STATUS="TP2"
    elif (( $(echo "$current >= $t_tp1" | bc -l) )); then TRADE_STATUS="TP1"
    else TRADE_STATUS="RUNNING"
    fi
  fi
fi

# Open a new trade if none is active
if [[ -z "$OPEN_TRADE" || "$OPEN_TRADE" == "null" ]]; then
  OPEN_TRADE=$(jq -n \
    --arg s  "$SYMBOL" \
    --arg e  "$ENTRY" \
    --arg t1 "$TP1" \
    --arg t2 "$TP2" \
    --arg t3 "$TP3" \
    --arg sl "$SL" \
    '{symbol:$s, entry:($e|tonumber), tp1:($t1|tonumber), tp2:($t2|tonumber), tp3:($t3|tonumber), sl:($sl|tonumber), opened:now}')
  [[ "$TRADE_STATUS" == "NONE" ]] && TRADE_STATUS="NEW_TRADE"
fi

OPEN_TRADE_AI=$(echo "$OPEN_TRADE" | jq -c '{
  symbol: (.symbol | sub("^s\"; \"\")),
  entry: ("$" + (.entry | tostring)),
  tp1:   ("$" + (.tp1   | tostring)),
  tp2:   ("$" + (.tp2   | tostring)),
  tp3:   ("$" + (.tp3   | tostring)),
  sl:    ("$" + (.sl    | tostring))
}')

# ── Scoreboard Stats ──────────────────────────────────────────
STATS_STR=$(jq -s '
  map(select(.result != null)) |
  (map(select(.result | startswith("TP"))) | length) as $w |
  (map(select(.result == "STOP_LOSS"))      | length) as $l |
  ($w + $l) as $t |
  if $t == 0 then "0 Wins - 0 Losses (0%)"
  else "\($w) Wins - \($l) Losses (\(($w * 100 / $t) | round)%)"
  end
' "$TRADE_HISTORY_FILE" 2>/dev/null || echo "0 Wins - 0 Losses (0%)")

# ── Persist trade state ────────────────────────────────────────
jq -n \
  --argjson open "${OPEN_TRADE:-null}" \
  --arg status "$TRADE_STATUS" \
  '{open_trade:$open, last_status:$status}' > "$STATE_FILE"

# ── Assemble AI payload 1: Structured Data ─────────────────────
info "Calling NVIDIA/Nebius ($MODEL) — Data Pass…"

SYSTEM_PROMPT_JSON='You are the lead analyst for The P.L.U.M.B.U.S. (Price Level Updates, Market Briefings, & Universal Signals).
Synthesize the provided data into a structured JSON briefing.

CRITICAL RULES:
1. Use ONLY the pre-formatted price strings provided. Never invent or recalculate price levels.
2. Never cross-reference prices between different assets. Each asset has its own price.
3. Never recycle entry/exit levels from closed trades into new setups.
4. If TRADE_STATUS is STOP_LOSS, write a 2-sentence post-mortem in position_tracking explaining why momentum failed.
5. Setups must reference assets from the WATCHLIST only, not the best candidate.
6. headline must name the specific ticker, include the exact price, and state ONE specific market dynamic.
7. Setups must distinguish between crypto spot, crypto perp, and stock perp assets where context is relevant.

Required JSON keys:
- headline, analysis, position_tracking, watchlist, outlook, setups (array of 3).'

USER_CONTENT_JSON="SCOREBOARD: $STATS_STR
TRADE STATUS: $TRADE_STATUS
ACTIVE TRADE: $OPEN_TRADE_AI
BEST CANDIDATE: $BEST_TRADE_AI
WATCHLIST: $WATCHLIST
PREVIOUS SESSION: ${PREV_BRIEF:-Opening transmission.}

Deliver the P.L.U.M.B.U.S. JSON briefing now."

PAYLOAD_JSON=$(jq -n \
  --arg model "$MODEL" \
  --arg temp  "$TEMPERATURE" \
  --argjson max "$MAX_TOKENS" \
  --arg sys  "$SYSTEM_PROMPT_JSON" \
  --arg data "$USER_CONTENT_JSON" \
  '{model:$model, temperature:($temp|tonumber), max_tokens:$max,
    response_format:{type:"json_object"},
    messages:[{role:"system",content:$sys},{role:"user",content:$data}]}')

# ── Assemble AI payload 2: Bloomberg Persona ──────────────────
info "Calling NVIDIA/Nebius ($MODEL) — Desk Pass…"

SYSTEM_PROMPT_BLOOMBERG="You are the voice of a premium crypto intelligence channel — think Bloomberg anchor meets trading desk veteran. You address the channel directly as 'traders' or 'the desk'. You write with urgency, confidence, and controlled excitement. Every brief opens like a live broadcast, references what played out from the previous session if data is provided, and closes with a clear forward-looking statement that makes members feel the next brief is unmissable.

Rules:
- Open with a punchy broadcast-style headline for today's session
- If previous brief context is provided, call back to 1-2 calls that played out (or didn't) — accountability builds trust
- Use active voice, present tense where possible
- Replace jargon with vivid plain language: 'directional efficiency' becomes 'clean relentless buying with no wasted moves'
- Bold the 3 final trade setups as if reading them live on air
- Close every brief with a forward teaser: what to watch before the next session
- Never use bullet points — flowing paragraphs only, like a script"

USER_CONTENT_BLOOMBERG="Previous session summary: ${PREV_BRIEF:-'No previous brief on record — this is our opening transmission.'}

Today's market signals:
${SPOT_SIGNALS}
${PERP_SIGNALS}

Deliver the full market intelligence brief now."

PAYLOAD_BLOOMBERG=$(jq -n \
  --arg model "$MODEL" \
  --arg temp  "$TEMPERATURE" \
  --argjson max "$MAX_TOKENS" \
  --arg sys  "$SYSTEM_PROMPT_BLOOMBERG" \
  --arg data "$USER_CONTENT_BLOOMBERG" \
  '{model:$model, temperature:($temp|tonumber), max_tokens:$max,
    messages:[{role:"system",content:$sys},{role:"user",content:$data}]}')

# ── Execute AI Calls ──────────────────────────────────────────
fetch_ai() {
  local payload="$1" label="$2" out_var_name="$3"
  local response="" attempt=1 delay="$RETRY_DELAY"
  while (( attempt <= RETRY_MAX )); do
    response=$(curl -sfL -X POST "$NVIDIA_URL" \
      -H "Authorization: Bearer $NVIDIA_KEY" \
      -H "Content-Type: application/json" \
      -d "$payload" 2>/dev/null) && break
    warn "API call $label failed (attempt $attempt/$RETRY_MAX)"
    (( attempt++ ))
    if (( attempt <= RETRY_MAX )); then sleep "$delay"; delay=$(( delay * 2 )); fi
  done
  [[ -z "$response" ]] && die "API $label did not respond."
  if jq -e '.error' <<<"$response" &>/dev/null; then
    die "API $label error: $(jq -r '.error.message // .error' <<<"$response")"
  fi
  eval "$out_var_name"='$(echo "$response")'
}

fetch_ai "$PAYLOAD_JSON" "JSON" "RESPONSE_JSON"
fetch_ai "$PAYLOAD_BLOOMBERG" "Bloomberg" "RESPONSE_BLOOMBERG"

JSON_OUT=$(jq -r '.choices[0].message.content // empty' <<<"$RESPONSE_JSON")
BLOOMBERG_OUT=$(jq -r '.choices[0].message.content // empty' <<<"$RESPONSE_BLOOMBERG")

# ── Save summary for next session ─────────────────────────────
HEADLINE=$(echo "$JSON_OUT" | jq -r '.headline')
OUTLOOK=$(echo "$JSON_OUT"  | jq -r '.outlook')
echo "$HEADLINE: $OUTLOOK" | cut -c1-200 > "$PREV_BRIEF_FILE"

# ── Token stats ────────────────────────────────────────────────
PROMPT_TOK=$(jq -r '.usage.prompt_tokens     // "?"' <<<"$RESPONSE_JSON")
COMPL_TOK=$(jq  -r '.usage.completion_tokens // "?"' <<<"$RESPONSE_JSON")
log "Tokens — prompt: ${PROMPT_TOK}, completion: ${COMPL_TOK}"

# ── Terminal output ────────────────────────────────────────────
echo -e "\n${BOLD}📡 THE P.L.U.M.B.U.S. TRANSMISSION${RESET}"
echo -e "${DIM}$(date '+%Y-%m-%d %H:%M %Z')${RESET}\n"
echo "$BLOOMBERG_OUT"
echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"

# ── Telegram Output ────────────────────────────────────────────
if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
  info "Sending to Telegram…"

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
  
  # Process Bloomberg output: strip 's' and wrap in <code> for tickers
  # Use regex to find tickers and apply cleanup. 
  # Note: sed in HTML mode needs careful escaping.
  BLOOMBERG_CLEAN=$(echo "$BLOOMBERG_OUT" | sed -E 's/\bs([A-Z0-9]+USDT)\b/<code>\1<\/code>/g')

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

  # Message 1: Structured
  curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" \
    -d parse_mode="HTML" \
    --data-urlencode "text=$FINAL_MSG" >/dev/null

  # Message 2: Conversational
  curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" \
    -d parse_mode="HTML" \
    --data-urlencode "text=$RAW_MSG" >/dev/null

  ok "Both Telegram messages sent."
fi

echo -e "\n${BOLD}DONE.${RESET}"
