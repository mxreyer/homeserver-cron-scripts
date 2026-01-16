#!/bin/bash
# ==============================================================================
# Script Name: paperless-trigger-backup.sh
# Description : Creates a backup of media, data, and database using the
#               "document exporter" https://docs.paperless-ngx.com/administration/#exporter,
#               extracts the resulting ZIP archive, and appends its contents to a Borg
#               repository for deduplication.
#
# Notes:
#  - We do not need to clean ${PAPERLESS_BACKUP_FOLDER}, the paperless exporter
#    is able to update an existing backup.
#
# Restore instructions :
#   1. Extract desired backup from borg repo.
#   2. Create zip archive backup.zip of backup.
#   3. Use the "document importer" https://docs.paperless-ngx.com/administration/#importer
#   4. Regenerate thumbnails and archives with document_thumbnails and document_archiver
# ==============================================================================

set -euo pipefail # exit on error, undef vars, or failed pipeline
set -o errtrace   # inherit ERR trap by functions, command subs, subshells 

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../CONFIG.sh"

# === Configuration ===
PAPERLESS_BACKUP_FOLDER="${DOCKER_BINDS_DIR}/paperless/export" # where paperless exporter puts backups

# === Step 1: Trigger paperless backup ===
echo "💾 Requesting paperless backup..."
if ! (docker compose -f ${DOCKER_COMPOSE_DIR}/paperless/compose.yaml exec -T webserver\
      document_exporter --delete --no-archive --no-thumbnail --no-progress-bar ../export); then
  echo "❌ Failed to create backup." >&2
  exit 1
fi

echo "✅ Backup created successfully."
