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
[[ -f "$ENV_FILE" ]] || die ".env file not found at '$ENV_FILE'. Export NVIDIA_KEY or set ENV_FILE."
                                                                                                          
# Security check: warn if .env is world-readable
if [[ -f "$ENV_FILE" && "$(stat -c %a "$ENV_FILE" 2>/dev/null || stat -f %Lp "$ENV_FILE" 2>/dev/null)" =~ [0-9][0-9][1357] ]]; then
  warn "$ENV_FILE has insecure permissions. Consider 'chmod 600 $ENV_FILE'."
fi

# shellcheck source=/dev/null
source "$ENV_FILE"
[[ -n "${NVIDIA_KEY:-}" ]] || die "NVIDIA_KEY is not set in $ENV_FILE"

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
      # Basic validation: check if it is valid JSON and has a .result array
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

# ── Compute each signal (all local, no extra network calls) ───
info "Computing signals…"

# Process Spot Signals in one pass
SPOT_SIGNALS=$(jq -c "
  .result as \$res
  | (\$res | map(select(.openEp != null and .openEp > 0))) as \$spot
  | {
      SIGNAL_OB: (
        \$spot
        | map({symbol, changePct: (((.lastEp - .openEp) / .openEp) * 100), lastPx: .lastEp})
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
      SIGNAL_WICK: (
        \$res | map(select(.highEp > .lowEp))
        | map({
            symbol,
            upperWick: ((.highEp - ([.lastEp, .openEp] | max)) / (.highEp - .lowEp) * 100),
            lowerWick: ((([.lastEp, .openEp] | min) - .lowEp) / (.highEp - .lowEp) * 100)
          })
        | { POTENTIAL_TOP_REJECTION: (sort_by(.upperWick) | .[-5:] | reverse), POTENTIAL_BOTTOM_ABSORPTION: (sort_by(.lowerWick) | .[-5:] | reverse) }
      ),
      SIGNAL_ALPHA: (
        ((\$res | .[] | select(.symbol == \"sBTCUSDT\") | ((.lastEp - .openEp) / .openEp * 100)) // 0) as \$btcChange
        | \$spot
        | map({symbol, changePct: ((.lastEp - .openEp) / .openEp * 100), vs_btc_alpha: (((.lastEp - .openEp) / .openEp * 100) - \$btcChange)})
        | sort_by(.vs_btc_alpha)
        | { MARKET_LEADERS_OVER_BTC: (.[-5:] | reverse), MARKET_LAGGARDS_UNDER_BTC: .[0:5] }
      ),
      SIGNAL_CHAN: (
        \$res | map(select(.highEp > .lowEp))
        | map({symbol, channelPos: ((.lastEp - .lowEp) / (.highEp - .lowEp) * 100)})
        | sort_by(.channelPos)
        | { HUGGING_24H_LOWS: .[0:5], HUGGING_24H_HIGHS: (.[-5:] | reverse) }
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
        | { CLEANEST_DOWNTREND: .[0:5], CLEANEST_UPTREND: (.[-5:] | reverse) }
      )
    }
" "$SPOT_RAW")

# Process Perp Signals in one pass
PERP_SIGNALS=$(jq -c "
  .result as \$res
  | (\$res | map(select(.fundingRateRr != null and (.openRp | tonumber) > 0))) as \$perp
  | {
      SIGNAL_FR: (
        \$perp
        | map({symbol, fundingRate: (.fundingRateRr | tonumber * 100), priceChange: (((.lastRp | tonumber) - (.openRp | tonumber)) / (.openRp | tonumber) * 100)})
        | sort_by(.fundingRate)
        | { SHORTS_CROWDED_POTENTIAL_SQUEEZE: .[0:5], LONGS_CROWDED_POTENTIAL_DUMP: (.[-5:] | reverse) }
      ),
      SIGNAL_OI: (
        \$res | map(select(.volumeRq != \"0\" and .volumeRq != null and .openInterestRv != null and (.volumeRq | tonumber) > $MIN_VOLUME))
        | map({symbol, oiToVolRatio: ((.openInterestRv | tonumber) / (.volumeRq | tonumber))})
        | sort_by(.oiToVolRatio)
        | { HEAVY_ACCUMULATION_HIGH_OI: (.[-5:] | reverse) }
      ),
      SIGNAL_SQUEEZE: (
        \$res | map(select(.fundingRateRr != null and .openInterestRv != null and .volumeRq != null and (.volumeRq | tonumber) > $MIN_VOLUME and (.fundingRateRr | tonumber) < 0))
        | map({symbol, funding: (.fundingRateRr | tonumber * 100), oiToVol: ((.openInterestRv | tonumber) / (.volumeRq | tonumber)), squeezeScore: ((-(.fundingRateRr | tonumber)) * ((.openInterestRv | tonumber) / (.volumeRq | tonumber)))})
        | sort_by(.squeezeScore) | reverse
        | { SHORT_SQUEEZE_COMPOSITE: .[0:7] }
      ),
      SIGNAL_DIV: (
        \$res | map(select(.openInterestRv != null and .openInterestChangeRv != null and (.volumeRq | tonumber) > $MIN_VOLUME and (.openInterestChangeRv | tonumber) > 0))
        | map({
            symbol,
            priceChange: (((.lastRp | tonumber) - (.openRp | tonumber)) / (.openRp | tonumber) * 100),
            oiChangePct: (.openInterestChangeRv | tonumber * 100),
            divergenceScore: ((.openInterestChangeRv | tonumber * 100) - (((.lastRp | tonumber) - (.openRp | tonumber)) / (.openRp | tonumber) * 100))
          })
        | sort_by(.divergenceScore) | reverse
        | { OI_PRICE_DIVERGENCE_COIL: .[0:5] }
      )
    }
" "$PERP_RAW")

ok "All signals computed."

# ── Assemble final payload ─────────────────────────────────────
info "Calling NVIDIA/Nebius ($MODEL) — Desk Pass…"

SYSTEM_PROMPT="You are the voice of a premium crypto intelligence channel — think Bloomberg anchor meets trading desk veteran. You address the channel directly as 'traders' or 'the desk'. You write with urgency, confidence, and controlled excitement. Every brief opens like a live broadcast, references what played out from the previous session if data is provided, and closes with a clear forward-looking statement that makes members feel the next brief is unmissable.

Rules:
- Open with a punchy broadcast-style headline for today's session
- If previous brief context is provided, call back to 1-2 calls that played out (or didn't) — accountability builds trust
- Use active voice, present tense where possible
- Replace jargon with vivid plain language: 'directional efficiency' becomes 'clean relentless buying with no wasted moves'
- Bold the 3 final trade setups as if reading them live on air
- Close every brief with a forward teaser: what to watch before the next session
- Never use bullet points — flowing paragraphs only, like a script"

USER_CONTENT="Previous session summary: ${PREV_BRIEF:-'No previous brief on record — this is our opening transmission.'}

Today's market signals:
${SPOT_SIGNALS}
${PERP_SIGNALS}

Deliver the full market intelligence brief now."

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
    messages: [
      { role: "system", content: $system },
      { role: "user",   content: $data   }
    ]
  }')

# ── Call NVIDIA API with retry ─────────────────────────────────
RESPONSE=""
attempt=1
delay="$RETRY_DELAY"
while (( attempt <= RETRY_MAX )); do
  RESPONSE=$(curl -sfL -X POST "$NVIDIA_URL" \
    -H "Authorization: Bearer $NVIDIA_KEY" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2> "$TMPDIR_LOCAL/api_err.txt") && break

  err_msg=$(cat "$TMPDIR_LOCAL/api_err.txt" 2>/dev/null || echo "Unknown error")
  warn "API call failed: $err_msg (attempt $attempt/$RETRY_MAX)"

  (( attempt++ ))
  if (( attempt <= RETRY_MAX )); then
    log "Retrying in ${delay}s..."
    sleep "$delay"
    delay=$(( delay * 2 ))
  fi
done

[[ -z "$RESPONSE" ]] && die "API did not respond after $RETRY_MAX attempts."

# Check for API-level error
if jq -e '.error' <<<"$RESPONSE" &>/dev/null; then
  die "API error: $(jq -r '.error.message // .error' <<<"$RESPONSE")"
fi

REPORT=$(jq -r '.choices[0].message.content // empty' <<<"$RESPONSE")
if [[ -z "$REPORT" ]]; then
  die "API returned an empty response. (Model may have hit MAX_TOKENS during reasoning)"
fi

# ── Save summary for next session ─────────────────────────────
echo "$RESPONSE" | jq -r '.choices[0].message.content' \
  | head -3 \
  | tr '\n' ' ' \
  | cut -c1-200 > "$PREV_BRIEF_FILE"

# ── Render output ──────────────────────────────────────────────
echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo "$REPORT" \
  | sed "s/^## \(.*\)/${BOLD}${CYAN}\1${RESET}/" \
  | sed "s/^\*\*\(.*\)\*\*/${BOLD}\1${RESET}/"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"

# ── Optional file save ─────────────────────────────────────────
if [[ "$SAVE_REPORT" == "true" ]]; then
  FILENAME="$REPORT_DIR/brief_$(date '+%Y%m%d_%H%M%S').md"
  {
    echo "# Market Intelligence Briefing"
    echo "_Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')_"
    echo ""
    echo "$REPORT"
  } > "$FILENAME"
  # Secure the saved report
  chmod 600 "$FILENAME"
  ok "Report saved → $FILENAME"
fi

# ── Usage / token stats ────────────────────────────────────────
PROMPT_TOK=$(jq -r '.usage.prompt_tokens     // "?"' <<<"$RESPONSE")
COMPL_TOK=$(jq  -r '.usage.completion_tokens // "?"' <<<"$RESPONSE")
log "Tokens used — prompt: ${PROMPT_TOK}, completion: ${COMPL_TOK}"
