#!/bin/bash
# ==============================================================================
# Script Name: auto-container-update.sh
# Description: Updates all docker compose projects. Should be run via cron like 
#               30 4 * * 1 /bin/bash -c '<scriptdir>/auto-container-update.sh >> <scriptdir>/logs/auto-container-update.log 2>&1'
# ==============================================================================

set -euo pipefail # exit on error, undef vars, or failed pipeline
set -o errtrace   # inherit ERR trap by functions, command subs, subshells 

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/CONFIG.sh"

# === Configuration === #
HEALTHCHECK_URL=$HCHK_CONTAINER_UPDATE # healthcheck ping url

tmp_docker_file=$(mktemp)
source "${SCRIPT_DIR}/container-handler.sh" || exit 1
source "${SCRIPT_DIR}/ping.sh"

# === Traps, error handling === #
on_exit() {
    start_docker || exit 1
    rm "$tmp_docker_file"
}
trap on_exit EXIT

on_error() {
    echo "❌ Update failed."
    ping_fail || exit 1
}
trap on_error ERR

# === Script logic === #

echo "----- ⬆️  Pulling container updates at $(date) ⏰ -----";

stop_docker || exit 1

pull_docker || exit 1

ping_success || exit 1

echo "✅ Updates complete."
