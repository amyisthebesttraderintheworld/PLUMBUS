#!/bin/bash
# Wrapper for The P.L.U.M.B.U.S. to ensure correct environment when run via cron

# Get the directory where the script is located
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR" || exit 1

# Ensure path is correct for binaries (jq, curl, etc)
export PATH="/usr/bin:/usr/local/bin:$PATH"

# Run the script
./scripts/plumbus.sh >> "$PROJECT_DIR/plumbus.log" 2>&1
