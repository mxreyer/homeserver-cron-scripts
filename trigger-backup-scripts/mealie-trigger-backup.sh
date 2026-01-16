#!/bin/bash
# ==============================================================================
# Script Name: mealie-trigger-backup.sh
# Description : Calls mealie API to create a backup, extracts the resulting ZIP
#               archive to a temporary dir for subsequent borg archiving
#
# Preparation :
#   1. Get mealie API key
#
# Restore instructions :
#   1. Extract desired backup from borg repo.
#   2. Create zip archive backup.zip of backup.
#   3. Upload to mealie instance via web interface or API.
# ==============================================================================

set -euo pipefail # exit on error, undef vars, or failed pipeline
set -o errtrace   # inherit ERR trap by functions, command subs, subshells 

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../CONFIG.sh"

# === Configuration ===
MEALIE_BACKUP_URL="https://mealie.${TS_DOMAIN}/api/admin/backups" # mealie api
MEALIE_AUTH_TOKEN="$APIKY_MEALIE" # mealie api token
MEALIE_BACKUP_FOLDER="${DOCKER_BINDS_DIR}/mealie/export" # this is where mealie puts backups
TMP_BACKUP_DIR="${DOCKER_BINDS_DIR}/mealie/backup"

tmpfile=$(mktemp)   # tmp file to store json response 
trap 'rm -rf "$tmpfile"' EXIT # delete tmp files

# === Step 0: Ensure tmp backup folder is empty ===
if [ -n "$(find ${MEALIE_BACKUP_FOLDER} -mindepth 1 -print -quit)" ]; then
  echo "❌ Tmp backup location is not empty."
  exit 1
else
  echo "✅ Backup location is empty."
fi

# === Step 1: Trigger mealie backup ===
echo "💾 Requesting mealie backup..."
status_code=$(curl -s -w "%{http_code}" -o "$tmpfile" \
  -X POST "$MEALIE_BACKUP_URL" \
  -H "Accept: application/json" \
  -H "Authorization: Bearer $MEALIE_AUTH_TOKEN")

if [[ "$status_code" -eq 201 ]]; then
  echo "✅ Backup created successfully."
else
  echo "❌ Failed to create backup."
  echo "➡️ Status code: $status_code"
  echo "➡️ Response: $(cat "$tmpfile")"
  exit 1
fi

# === Step 2: Extract generated backup ===
zipfile=(${MEALIE_BACKUP_FOLDER}/*.zip)
if [ ${#zipfile[@]} -eq 0 ]; then
  echo "❌ Not exactly one backup .zip file found in $MEALIE_BACKUP_FOLDER"
  exit 1
fi
zipfile="${zipfile[0]}"
echo "✅ Found backup .zip file: ${zipfile}"

[[ -d "$TMP_BACKUP_DIR" ]] && rm -rf "$TMP_BACKUP_DIR"
mkdir -p "$TMP_BACKUP_DIR"
unzip -q "$zipfile" -d "$TMP_BACKUP_DIR"
echo "Extracted .zip contents to ${TMP_BACKUP_DIR}."

# === Step 3: Delete tmp backup via API ===
echo "🗑️ Requesting deletion of tmp backup file..."
status_code=$(curl -s -w "%{http_code}" -o "$tmpfile" \
  -X DELETE "${MEALIE_BACKUP_URL}/$(basename ${zipfile})" \
  -H "Accept: application/json" \
  -H "Authorization: Bearer $MEALIE_AUTH_TOKEN")

if [[ "$status_code" -eq 200 ]]; then
  echo "✅ Tmp backup file deleted successfully."
else
  echo "❌ Failed to delete tmp backup file."
  echo "➡️ Status code: $status_code"
  echo "➡️ Response: $(cat "$tmpfile")"
  exit 1
fi
