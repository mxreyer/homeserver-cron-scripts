#!/bin/bash
# ==============================================================================
# Script Name: webservice-health-ping.sh
# Description : Ping container web urls and ping healthcheck if successful. Should be
#               scheduled with cron, e.g.
#               0 * * * * /bin/bash -c '<scriptdir>/webservice-health-ping.sh >> <scriptdir>/webservice-health-ping.log 2>&1'
# ==============================================================================

set -euo pipefail # exit on error, undef vars, or failed pipeline
set -o errtrace   # inherit ERR trap by functions, command subs, subshells 

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/CONFIG.sh"

HEALTHCHECK_URL="$HCHK_WEBSERVICE_PING"
source "${SCRIPT_DIR}/ping.sh"

on_error() {
  echo "❌ webservice health check failed. 🛜 ping failure."
  ping_fail || exit 1
}
trap on_error ERR

echo "----- 🕸️ Pinging docker services at $(date) ⏰ -----";

for SERVICE in $WEB_SERVICES; do
  URL="https://$SERVICE.$TS_DOMAIN"
  echo "check ${URL}..."
  curl --silent --fail --max-time 5 "$URL" > /dev/null
  echo "online ✅"
done

ping_success || exit 1
