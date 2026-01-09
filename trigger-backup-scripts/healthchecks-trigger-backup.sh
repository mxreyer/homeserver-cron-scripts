#!/bin/bash
# ==============================================================================
# Script Name: healthchecks.sh
# Description: Stops all healthchecks-* docker containers, dumps the postgres
#              database to a temporary dir for subsequent borg archiving
#
# Restore instructions:
#     - Start db container alone (w/o the web container),
#       read in database dump, then start web container?
#       (Like for immich...)
# ==============================================================================

set -euo pipefail # exit on error, undef vars, or failed pipeline
set -o errtrace   # inherit ERR trap by functions, command subs, subshells 

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../CONFIG.sh"

#should first stop web container...
#docker compose -f "${DOCKER_COMPOSE_DIR}/healthchecks/compose.yaml" stop web 
#... and then restart
##trap 'docker compose -f "${DOCKER_COMPOSE_DIR}/healthchecks/compose.yaml" start web' EXIT

# === Configuration ===
TMP_BACKUP_DIR="${DOCKER_BINDS_DIR}/healthchecks/backup"

# === Dump database ===
echo "💩 dumping postgres database..."
if ! (docker exec -t healthchecks-db-1 pg_dumpall --clean --if-exists --username=postgres > ${TMP_BACKUP_DIR}/healthchecks_postgres_dump.sql); then
    echo "❌ Database dump failed."
    exit 1
fi
echo "✅ Dumped database to ${TMP_BACKUP_DIR}/healthchecks_postgres_dump.sql."
