#!/bin/bash
# ==============================================================================
# Script Name: server-health-ping.sh
# Description : Ping healthcheck to signal that server is alive. Should be
#               scheduled with cron, e.g.
#               0 * * * * /bin/bash -c '$HOME/ping/server-health-ping.sh >> $HOME/ping/server-health-ping.log 2>&1'
# ==============================================================================

set -euo pipefail # exit on error, undef vars, or failed pipeline
set -o errtrace   # inherit ERR trap by functions, command subs, subshells 

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/CONFIG.sh"

# === Configuration ===
HEALTHCHECK_URL="$HCHK_SERVER_PING"

echo "----- 🛜 Pinging healthcheck at $(date) ⏰ -----"; 

# === Ping healthcheck ===
if ! curl -fsS --max-time 10 "$HEALTHCHECK_URL" >/dev/null; then
    echo "⚠️ Healthcheck ping failed." >&2
    exit 1
fi

echo "✅ Healthcheck ping successful!"
