#!/bin/bash
# ============================================================
#  MARKET INTELLIGENCE BRIEFING  —  Phemex → NVIDIA
# ============================================================                                            
set -euo pipefail

# ── Config ────────────────────────────────────────────────────                                          
ENV_FILE="${ENV_FILE:-.env}"
MODEL="${NVIDIA_MODEL:-nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B}"
TEMPERATURE="${NVIDIA_TEMPERATURE:-0.5}"
MAX_TOKENS="${NVIDIA_MAX_TOKENS:-4096}"                                                                   
MIN_VOLUME="${MIN_VOLUME:-10000}"          # filter out low-volume noise (USD equiv)                      
SAVE_REPORT="${SAVE_REPORT:-false}"        # set SAVE_REPORT=true to write to disk
REPORT_DIR="${REPORT_DIR:-./reports}"                                                                     
RETRY_MAX=3                                                                                               
RETRY_DELAY=2                                                                                             
PHEMEX_SPOT="https://api.phemex.com/md/spot/ticker/24hr/all"                                              
PHEMEX_PERP="https://api.phemex.com/md/v3/ticker/24hr/all"                                                
NVIDIA_URL="https://api.tokenfactory.nebius.com/v1/chat/completions"                                      
TMPDIR_LOCAL=$(mktemp -d)                                                                                 
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT INT TERM                                                               

STATE_FILE="${STATE_FILE:-./trade_state.json}"
TRADE_HISTORY_FILE="${TRADE_HISTORY_FILE:-./trade_history.json}"
PREV_BRIEF_FILE="${PREV_BRIEF_FILE:-./last_brief.txt}"                                                    
PREV_BRIEF=""                                                                                             
[[ -f "$PREV_BRIEF_FILE" ]] && PREV_BRIEF=$(cat "$PREV_BRIEF_FILE")                                                                                                                                                 

# ── Colors ────────────────────────────────────────────────────                                          
ESC=$(printf '\033')                                                                                      
RED="${ESC}[0;31m"; YELLOW="${ESC}[1;33m"; GREEN="${ESC}[0;32m"                                           
CYAN="${ESC}[0;36m"; BOLD="${ESC}[1m"; DIM="${ESC}[2m"; RESET="${ESC}[0m"
                                                                                                          
# ── Helpers ───────────────────────────────────────────────────
log()   { echo -e "${DIM}[$(date +%H:%M:%S)]${RESET} $*" >&2; }                                           
info()  { echo -e "${CYAN}▸${RESET} $*" >&2; }
ok()    { echo -e "${GREEN}✔${RESET} $*" >&2; }
warn()  { echo -e "${YELLOW}⚠${RESET}  $*" >&2; }                                                         
die()   { echo -e "${RED}✖  ERROR:${RESET} $*" >&2; exit 1; }

# ── Preflight checks ──────────────────────────────────────────                                          
if [[ -f "$ENV_FILE" ]]; then
  if [[ "$(stat -c %a "$ENV_FILE" 2>/dev/null || stat -f %Lp "$ENV_FILE" 2>/dev/null)" =~ [0-9][0-9][1357] ]]; then
    warn "$ENV_FILE has insecure permissions. Consider 'chmod 600 $ENV_FILE'."
  fi
  source "$ENV_FILE"
fi

[[ -n "${NVIDIA_KEY:-}" ]] || die "NVIDIA_KEY is not set. Set it in $ENV_FILE or as an environment variable."
command -v jq  &>/dev/null || die "jq is required but not installed."
command -v curl &>/dev/null || die "curl is required but not installed."

if [[ "$SAVE_REPORT" == "true" ]]; then
  mkdir -p "$REPORT_DIR"
fi

# ── Retry-aware curl wrapper with backoff ──────────────────────
fetch() {
  local url="$1" out="$2" label="${3:-Data}" attempt=1 delay="$RETRY_DELAY"
  while (( attempt <= RETRY_MAX )); do
    if curl -sfL --max-time 15 "$url" -o "$out" 2> "$TMPDIR_LOCAL/curl_err.txt"; then
      if jq -e '.result | type == "array"' "$out" >/dev/null 2>&1; then
        return 0
      elif jq -e '.code != null and .code != 0' "$out" >/dev/null 2>&1; then
        local msg=$(jq -r '.msg // "Unknown API error"' "$out")
        warn "$label API error: $msg (attempt $attempt/$RETRY_MAX)"
      else
        warn "$label returned invalid structure (attempt $attempt/$RETRY_MAX)"
      fi
    else
      local err=$(cat "$TMPDIR_LOCAL/curl_err.txt" 2>/dev/null || echo "Unknown error")
      warn "$label fetch failed: $err (attempt $attempt/$RETRY_MAX)"
    fi
    (( attempt++ ))
    if (( attempt <= RETRY_MAX )); then
      log "Retrying in ${delay}s..."
      sleep "$delay"
      delay=$(( delay * 2 ))
    fi
  done
  echo "FAILED" > "$out.status"
  return 1
}

# ── Parallel data fetch ────────────────────────────────────────
echo -e "\n${BOLD}  MARKET INTELLIGENCE BRIEFING${RESET}  ${DIM}$(date '+%Y-%m-%d %H:%M:%S %Z')${RESET}\n"
info "Fetching market data in parallel…"

SPOT_RAW="$TMPDIR_LOCAL/spot.json"
PERP_RAW="$TMPDIR_LOCAL/perp.json"

fetch "$PHEMEX_SPOT" "$SPOT_RAW" "Spot" &
fetch "$PHEMEX_PERP" "$PERP_RAW" "Perp" &
wait

if [[ -f "$SPOT_RAW.status" ]] || [[ -f "$PERP_RAW.status" ]]; then
  die "One or more data fetches failed."
fi

ok "Raw data fetched and validated."

# ── Compute each signal ───────────────────────────────────────
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
      SIGNAL_LIQ: (
        \$res | map(select(.bidEp > 0 and .askEp > 0))
        | map({symbol, spreadPct: (((.askEp - .bidEp) / .bidEp) * 100)})
        | sort_by(.spreadPct)
        | { MOST_LIQUID_LOW_SLIPPAGE: .[0:5], LOWEST_LIQUIDITY_HIGH_RISK: (.[-5:] | reverse) }
      ),
      SIGNAL_VOL: (
        \$res | map(select(.lowEp > 0 and .highEp > .lowEp))
        | map({symbol, rangePct: (((.highEp - .lowEp) / .lowEp) * 100)})
        | sort_by(.rangePct)
        | { MAX_INTRADAY_VOLATILITY: (.[-10:] | reverse) }
      ),
      SIGNAL_ALPHA: (
        ((\$res | .[] | select(.symbol == \"sBTCUSDT\") | ((.lastEp - .openEp) / .openEp * 100)) // 0) as \$btcChange
        | \$spot
        | map({symbol, changePct: ((.lastEp - .openEp) / .openEp * 100), vs_btc_alpha: (((.lastEp - .openEp) / .openEp * 100) - \$btcChange)})
        | sort_by(.vs_btc_alpha)
        | { MARKET_LEADERS_OVER_BTC: (.[-5:] | reverse), MARKET_LAGGARDS_UNDER_BTC: .[0:5] }
      ),
      SIGNAL_TREND: (
        \$res | map(select(.highEp > .lowEp and .openEp > 0))
        | map({
            symbol,
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
        | map({symbol, fundingRate: (.fundingRateRr | tonumber * 100), priceChange: (((.lastRp | tonumber) - (.openRp | tonumber)) / (.openRp | tonumber) * 100)})
        | sort_by(.fundingRate)
        | { SHORTS_CROWDED_POTENTIAL_SQUEEZE: .[0:5], LONGS_CROWDED_POTENTIAL_DUMP: (.[-5:] | reverse) }
      )
    }
" "$PERP_RAW")

ok "Signals computed."

# ── Data Assembly for AI ──────────────────────────────────────
# Build Watchlist
WATCHLIST=$(jq -c "{
  OVERSOLD:       (.SIGNAL_OB.MOST_OVERSOLD_PROXY[:3]  | map((.symbol | sub(\"^s\"; \"\")) + \" (\$\" + (.lastPx | tostring) + \")\")),
  OVERBOUGHT:     (.SIGNAL_OB.MOST_OVERBOUGHT_PROXY[:3] | map((.symbol | sub(\"^s\"; \"\")) + \" (\$\" + (.lastPx | tostring) + \")\")),
  FUNDING_SQUEEZE:(\$PERP.SIGNAL_FR.SHORTS_CROWDED_POTENTIAL_SQUEEZE[:3] | map((.symbol | sub(\"^s\"; \"\")) + \" (\$\" + (.lastPx | tostring) + \")\"))
}" --argjson PERP "$PERP_SIGNALS" <<< "$SPOT_SIGNALS")

# Load Scoreboard
STATS_STR=$(jq -s '
  map(select(.result != null)) |
  (map(select(.result | startswith("TP"))) | length) as $w |
  (map(select(.result == "STOP_LOSS"))      | length) as $l |
  ($w + $l) as $t |
  if $t == 0 then "0 Wins - 0 Losses (0%)"
  else "\($w) Wins - \($l) Losses (\(($w * 100 / $t) | round)%)"
  end
' "$TRADE_HISTORY_FILE" 2>/dev/null || echo "0 Wins - 0 Losses (0%)")

# ── Assemble AI payload ─────────────────────────────────────
info "Calling NVIDIA/Nebius ($MODEL) — Full Intelligence Pass…"

SYSTEM_PROMPT='You are the lead analyst for The P.L.U.M.B.U.S. (Price Level Updates, Market Briefings, & Universal Signals).
Synthesize the provided data into a structured JSON briefing containing two distinct versions of the report.

CRITICAL RULES:
1. "briefing_json" contains the structured detailed data. 
2. "briefing_raw" is a conversational, broadcast-style paragraph (Bloomberg style) addressing "the desk". 
3. You MUST use clean ticker names in "briefing_raw" (e.g., BTCUSDT, not sBTCUSDT). 
4. Start "briefing_raw" with a punchy hook. (max 1000 chars). No bullet points.

Required JSON keys:
- headline: Punchy single-line session summary (max 100 chars).
- analysis: Detailed paragraph synthesizing the signal narrative (max 500 chars).
- position_tracking: Current market position narrative or recent trade update.
- watchlist: Clean multi-line grouped list: "📍 OVERSOLD:\n• TICKER ($price)\n📍 OVERBOUGHT:\n• ...\n📍 FUNDING SQUEEZE:\n• ..."
- outlook: Strategic forward-looking teaser (max 250 chars).
- setups: Array of exactly 3 setup strings for WATCHLIST assets (max 150 chars each).
- briefing_raw: The conversational paragraph.'

USER_CONTENT="SCOREBOARD: $STATS_STR
SIGNALS: ${SPOT_SIGNALS} ${PERP_SIGNALS}
WATCHLIST: $WATCHLIST
PREVIOUS SESSION: ${PREV_BRIEF:-Opening transmission.}

Deliver the P.L.U.M.B.U.S. dual-mode JSON briefing now."

PAYLOAD=$(jq -n \
  --arg model       "$MODEL" \
  --arg temperature "$TEMPERATURE" \
  --argjson max_tok "$MAX_TOKENS" \
  --arg system      "$SYSTEM_PROMPT" \
  --arg data        "$USER_CONTENT" \
  '{
    model:       $model,
    temperature: ($temperature | tonumber),
    max_tokens:  $max_tok,
    response_format: { type: "json_object" },
    messages: [
      { role: "system", content: $system },
      { role: "user",   content: $data   }
    ]
  }')

# ── Call AI with retry ─────────────────────────────────────────
RESPONSE=""
attempt=1; delay="$RETRY_DELAY"
while (( attempt <= RETRY_MAX )); do
  RESPONSE=$(curl -sfL -X POST "$NVIDIA_URL" \
    -H "Authorization: Bearer $NVIDIA_KEY" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2> "$TMPDIR_LOCAL/api_err.txt") && break
  warn "API call failed (attempt $attempt/$RETRY_MAX)"
  (( attempt++ ))
  if (( attempt <= RETRY_MAX )); then sleep "$delay"; delay=$(( delay * 2 )); fi
done

[[ -z "$RESPONSE" ]] && die "API did not respond."
if jq -e '.error' <<<"$RESPONSE" &>/dev/null; then
  die "API error: $(jq -r '.error.message // .error' <<<"$RESPONSE")"
fi

JSON_OUT=$(jq -r '.choices[0].message.content // empty' <<<"$RESPONSE")
[[ -z "$JSON_OUT" ]] && die "API returned empty response."

# ── Save summary for next session ─────────────────────────────
HEADLINE=$(echo "$JSON_OUT" | jq -r '.headline')
OUTLOOK=$(echo "$JSON_OUT"  | jq -r '.outlook')
echo "$HEADLINE: $OUTLOOK" | cut -c1-200 > "$PREV_BRIEF_FILE"

# ── Telegram Output ────────────────────────────────────────────
if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
  info "Broadcasting Transmission..."

  esc() { echo "$1" | sed 's/</\&lt;/g; s/>/\&gt;/g'; }
  
  TIME_STAMP=$(date '+%Y-%m-%d | %H:%M %Z')
  ANALYSIS_ESC=$(esc "$(echo "$JSON_OUT" | jq -r '.analysis')")
  POS_TRACK_ESC=$(esc "$(echo "$JSON_OUT" | jq -r '.position_tracking')")
  WATCHLIST_ESC=$(esc "$(echo "$JSON_OUT" | jq -r '.watchlist')")
  OUTLOOK_ESC=$(esc "$OUTLOOK")
  HEADLINE_ESC=$(esc "$HEADLINE")
  SETUPS_HTML=$(echo "$JSON_OUT" | jq -r '.setups[]' | sed 's/</\&lt;/g; s/>/\&gt;/g' | sed 's/^/• /')
  
  # Message 1: Structured P.L.U.M.B.U.S. Transmission
  FINAL_MSG="📡 <b>THE P.L.U.M.B.U.S. TRANSMISSION</b>
📅 <code>${TIME_STAMP}</code>

📈 <b>SCOREBOARD</b>
<blockquote>${STATS_STR}</blockquote>

<b>SESSION HEADLINE</b>
<blockquote>${HEADLINE_ESC}</blockquote>

📊 <b>DESK ANALYSIS</b>
${ANALYSIS_ESC}

🎯 <b>POSITION TRACKING</b>
${POS_TRACK_ESC}

🔍 <b>ON RADAR</b>
${WATCHLIST_ESC}

🔭 <b>FORWARD OUTLOOK</b>
${OUTLOOK_ESC}

⚡ <b>HIGH-CONVICTION SETUPS</b>
${SETUPS_HTML}"

  curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" \
    -d parse_mode="HTML" \
    --data-urlencode "text=$FINAL_MSG" >/dev/null

  # Message 2: Conversational Bloomberg Briefing
  BLOOMBERG_OUT=$(echo "$JSON_OUT" | jq -r '.briefing_raw')
  BLOOMBERG_CLEAN=$(echo "$BLOOMBERG_OUT" | sed 's/\*\*\([^*]*\)\*\*/<b>\1<\/b>/g' | sed -E 's/\bs([A-Z0-9]+USDT)\b/<code>\1<\/code>/g')

  RAW_MSG="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

${BLOOMBERG_CLEAN}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" \
    -d parse_mode="HTML" \
    --data-urlencode "text=$RAW_MSG" >/dev/null

  ok "Dual-message transmission complete."
fi

# ── Usage / token stats ────────────────────────────────────────
PROMPT_TOK=$(jq -r '.usage.prompt_tokens     // "?"' <<<"$RESPONSE")
COMPL_TOK=$(jq  -r '.usage.completion_tokens // "?"' <<<"$RESPONSE")
log "Tokens used — prompt: ${PROMPT_TOK}, completion: ${COMPL_TOK}"
