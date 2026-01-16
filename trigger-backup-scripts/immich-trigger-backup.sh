#!/bin/bash
# ==============================================================================
# Script Name: immich.sh
# Description: Stops all immich-* docker containers, dumps the postgres
#              database,
#              appends it to a Borg repository for deduplication,
#              following https://docs.immich.app/guides/template-backup-script/
#              (also see https://docs.immich.app/administration/backup-and-restore/)
#
# Restore instructions : See above links.
# ==============================================================================

set -euo pipefail # exit on error, undef vars, or failed pipeline
set -o errtrace   # inherit ERR trap by functions, command subs, subshells 

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../CONFIG.sh"

# should stop and later restart containers...
#docker compose -f "$DOCKER_COMPOSE_DIR/immich/compose.yaml stop immich-server immich-machine-learning redis"
#trap 'docker compose -f "$DOCKER_COMPOSE_DIR/immich/compose.yaml start redis immich-machine-learning immich-server' EXIT"

# === Configuration ===
IMMICH_UPLOAD_LOCATION="${DOCKER_BINDS_DIR}/immich/library"

# === Dumping database ===
echo "💩 dumping postgres database..."
dumpfiledest="$IMMICH_UPLOAD_LOCATION"/database-backup/immich-database.sql
if ! (docker exec -t immich-database-1 pg_dumpall --clean --if-exists --username=postgres > "$dumpfiledest"); then
  echo "❌ Database dump failed."
  exit 1
fi
echo "✅ Dumped database to ${dumpfiledest}."

