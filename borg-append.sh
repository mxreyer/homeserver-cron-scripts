#!/bin/bash
# ==============================================================================
# Script Name: borg-append.sh
# Description: Append source files/dirs to (encrypted) borg repo.
#
# Usage: borg-append.sh -p backup_pass_file -d backup_dest_1 -d backup_dest_2 -s source1 -s source2
#
# Notes: Need to execute borg with sudo if the source files are owned by root.
#
# Preparation: Initialize the borg repo and create the corresponding passkey file (chmod 600).
# ==============================================================================

set -euo pipefail # exit on error, undef vars, or failed pipeline
set -o errtrace   # inherit ERR trap by functions, command subs, subshells 

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# === Parse arguments ==
BACKUP_SRCS=()
BACKUP_DESTS=()
BACKUP_EXCL=()
BORG_PASS_FILE=""
BORG_CHECK=""
while getopts "s:d:e:p:c" opt; do
    case "$opt" in
	s) BACKUP_SRCS+=("$OPTARG") ;;
	d) BACKUP_DESTS+=("$OPTARG") ;;
	e) BACKUP_EXCL+=("$OPTARG") ;;
        p) BORG_PASS_FILE="$OPTARG" ;;
        c) BORG_CHECK="yes" ;;
    esac
done
shift $((OPTIND - 1))
#REMAINING_ARGS="$@";
BORG_FLAGS="$@"

# === Error handling ==
on_exit() {
    unset BORG_PASSPHRASE # for security, unset passphrase
}
trap on_exit EXIT

on_error() {
    echo "❌ Appending to borg repo failed."
    exit 1
}
trap on_error ERR

# === Check user input ===
#if [[ ! -z $REMAINING_ARGS ]]; then
#    echo "❌ Extra arguments: '${REMAINING_ARGS}'" >&2  
#    exit 1
#fi
if [[ -z "${BACKUP_SRCS[@]}" ]] || [[ -z "${BACKUP_DESTS[@]}" ]]; then
    echo "❌ Specify at least one source and destination for the backup!" >&2  
    exit 1
fi
if [[ -z $BORG_PASS_FILE ]]; then
    echo "❌ Must specify passfile!" >&2  
    exit 1
fi
if [[ ! -f $BORG_PASS_FILE ]]; then
    echo "❌ Couldn't find passfile: '${BORG_PASS_FILE}'" >&2  
    exit 1
fi
read -r BORG_PASSPHRASE < "$BORG_PASS_FILE"
for src in "${BACKUP_SRCS[@]}"; do
    if [[ ! -e "$src" ]]; then
        echo "❌ Source '$src' is not a valid file or directory." >&2
        exit 1
    fi
done
for dest in "${BACKUP_DESTS[@]}"; do
    if ! $(sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg info "$dest" > /dev/null); then
        echo "❌ '$dest' is not a valid or accessible Borg repository." >&2
        exit 1
    fi 
done

# === Script logic ===
echo "🤖 Append to borg backup..."
echo "💾 Sources: ${BACKUP_SRCS[@]}"
echo "👎 Exclude: ${BACKUP_EXCL[@]}"
echo "🗄️  Borg repos: ${BACKUP_DESTS[@]}"
echo "🏳️  Borg flags: $BORG_FLAGS"

for dest in "${BACKUP_DESTS[@]}"; do
    echo "➡️  Append to repo: ${dest}"
    echo "borg check... ($(date))"
    [[ "$BORG_CHECK" == "yes" ]] && sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg check --verify-data "$dest"
    echo "borg create... ($(date))"
    exclargs=$( (( ${#BACKUP_EXCL[@]} == 0 ))  || printf -- "-e %s " "${BACKUP_EXCL[@]}")
    sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg create "$dest"::"{now}" "${BACKUP_SRCS[@]}" $exclargs $BORG_FLAGS
    echo "borg prune... ($(date))"
    sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg prune --keep-weekly=4 --keep-monthly=3 "$dest"
    echo "borg compact... ($(date))"
    sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg compact "$dest"
done

echo "✅ Successfully appended backups to borg repos."
