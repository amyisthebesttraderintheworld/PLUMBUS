#!/bin/bash
# P.L.U.M.B.U.S. Setup Script

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

echo "Setting up P.L.U.M.B.U.S. environment..."

# 1. Create necessary directories
echo "Creating directories..."
mkdir -p data assets/generated reports

# 2. Set permissions
echo "Setting permissions..."
chmod +x run.sh
chmod +x scripts/plumbus.sh
chmod +x scripts/health_monitor.sh
chmod +x scripts/log_rotation.sh

# 3. Check for dependencies
echo "Checking dependencies..."
for cmd in jq curl bc openssl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "WARNING: $cmd is not installed. Please install it."
    else
        echo "  - $cmd found."
    fi
done

# 4. Reset inaugural state (to ensure next run is inaugural)
echo "Resetting inaugural state..."
rm -f data/inaugural_sent data/last_brief.txt

# 5. Initialize trade state if missing
if [[ ! -f "data/trade_state.json" ]]; then
    echo "Initializing trade state..."
    echo '{"open_trade":null,"last_status":"NONE"}' > data/trade_state.json
fi

if [[ ! -f "data/trade_history.json" ]]; then
    echo "Initializing trade history..."
    echo '[]' > data/trade_history.json
fi

echo "Setup complete! You can now run the bot with ./run.sh"
