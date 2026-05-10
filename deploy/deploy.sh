#!/bin/bash
# ============================================================
#  The P.L.U.M.B.U.S. OCI Deployment Automator
#  Automates deps, permissions, and crontab setup.
# ============================================================

set -euo pipefail

echo "📦 Installing dependencies (jq, bc, curl)..."
apt update && apt install -y jq bc curl

echo "🔐 Setting execution permissions..."
chmod +x /home/ubuntu/paid_channel/scripts/*.sh /home/ubuntu/paid_channel/*.sh

echo "⏰ Configuring crontab..."
CRON_BRIEF="0 9 * * * /home/ubuntu/paid_channel/run.sh"
CRON_SENTRY="*/15 * * * * /home/ubuntu/paid_channel/scripts/sentry.sh >> /home/ubuntu/paid_channel/sentry.log 2>&1"

# Export existing crontab, or create empty if none exists
TMP_CRON=$(mktemp)
crontab -l > "$TMP_CRON" 2>/dev/null || true

# Add jobs only if they are not already present
grep -q "run.sh" "$TMP_CRON" || (echo "$CRON_BRIEF" >> "$TMP_CRON" && echo "  + Added briefing cron")
grep -q "sentry.sh" "$TMP_CRON" || (echo "$CRON_SENTRY" >> "$TMP_CRON" && echo "  + Added sentry cron")

# Apply the new crontab
crontab "$TMP_CRON"
rm "$TMP_CRON"

echo "✅ OCI Setup Complete. The P.L.U.M.B.U.S. is now autonomous."
