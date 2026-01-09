#!/bin/bash
# ==============================================================================
# Script Name: beszel-trigger-backup.sh
# Description : Calls beszel API to create a backup, extracts the resulting ZIP
#               archive to a temporary dir for subsequent borg archiving
#
# Preparation :
#   1. Get beszel API key
#
# Restore instructions :
#   1. Extract desired backup from borg repo. It should contain a
#      folder `backup` and a file `backup.zip.attr`
#   2. Create zip archive backup.zip of `backup` folder.
#   3. Upload backup.zip and backup.zip.attr to beszel instance via web
#      interface or API.
# ==============================================================================

set -euo pipefail # exit on error, undef vars, or failed pipeline
set -o errtrace   # inherit ERR trap by functions, command subs, subshells 

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/CONFIG.sh"

# === Configuration ===
BESZEL_BACKUP_URL="https://beszel.${TS_DOMAIN}/api/backups" # beszel api
BESZEL_AUTH_TOKEN="$APIKY_BESZEL" # beszel api token
BESZEL_BACKUP_FOLDER="${DOCKER_BINDS_DIR}/beszel/beszel_data/backups/" # this is where beszel puts backups
TMP_BACKUP_DIR="${DOCKER_BINDS_DIR}/beszel/backup"

tmpfile=$(mktemp)   # tmp file to store json response 
trap 'rm -rf "$tmpfile"' EXIT # delete tmp files

# === Step 0: Ensure tmp backup folder is empty ===
if [ -n "$(find ${BESZEL_BACKUP_FOLDER} -mindepth 1 -print -quit)" ]; then
    echo "❌ Tmp backup location is not empty."
    exit 1
else
    echo "✅ Backup location is empty."
fi

# === Step 1: Trigger beszel backup ===
echo "💾 Requesting beszel backup..."
status_code=$(curl -s -w "%{http_code}" -o "$tmpfile" \
  -X POST "$BESZEL_BACKUP_URL" \
  -H "Accept: application/json" \
  -H "Authorization: Bearer $BESZEL_AUTH_TOKEN")

if [[ "$status_code" -eq 204 ]]; then
    echo "✅ Backup created successfully."
else
    echo "❌ Failed to create backup."
    echo "➡️  Status code: $status_code"
    message=$(jq -r '.message // ""' "$tmpfile")
    echo "➡️  Message: $message"
    exit 1
fi

# === Step 2: Extract generated backup ===
zipfile=(${BESZEL_BACKUP_FOLDER}/*.zip)
if [ ${#zipfile[@]} -eq 0 ]; then
    echo "❌ Not exactly one backup .zip file found in $BESZEL_BACKUP_FOLDER"
    exit 1
fi
zipfile="${zipfile[0]}"
echo "✅ Found backup .zip file: ${zipfile}"

attrsfile="${zipfile}.attrs"
if [ ! -f "$attrsfile" ]; then
    echo "❌ Missing .zip.attrs file ${attrsfile}"
    exit 1
fi
echo "✅ Found .zip.attrs file: ${attrsfile}"

[[ -d ${TMP_BACKUP_DIR} ]] && rm -rf ${TMP_BACKUP_DIR}
mkdir -p "${TMP_BACKUP_DIR}/backup"
unzip -q "$zipfile" -d "${TMP_BACKUP_DIR}/backup"
echo "Extracted .zip contents to ${TMP_BACKUP_DIR}/backup."
cp "$attrsfile" "${TMP_BACKUP_DIR}/backup.zip.attrs"
echo "Copied .zip.attrs file to ${TMP_BACKUP_DIR}/backup.zip.attrs."

# === Step 4: Delete tmp backup via API ===
echo "🗑️ Requesting deletion of tmp backup file..."
status_code=$(curl -s -w "%{http_code}" -o "$tmpfile" \
  -X DELETE "${BESZEL_BACKUP_URL}/$(basename ${zipfile})" \
  -H "Accept: application/json" \
  -H "Authorization: Bearer $BESZEL_AUTH_TOKEN")

if [[ "$status_code" -eq 204 ]]; then
    echo "✅ Tmp backup file deleted successfully."
else
    echo "❌ Failed to delete tmp backup file."
    echo "➡️ Status code: $status_code"
    message=$(jq -r '.message // ""' "$tmpfile")
    echo "➡️ Message: $message"
    exit 1
fi
