#!/bin/bash
# ==============================================================================
# Script Name: server-backup.sh
# Description : Back up server data via borg. Docker data is excluded.
#               Should be scheduled with cron, e.g.
#               0 3 * * * /bin/bash -c '<scriptdir>/pi-backup.sh >> <scriptdir>/logs/pi-backup.log 2>&1'
# Preparation:
#     - Initialize borg repos (borg init --encryption=repokey /path/to/repo)
#     - Store Borg passphrase in .borg-pass-XXX (chmod 600).
#
# Notes:
# ==============================================================================

set -euo pipefail # exit on error, undef vars, or failed pipeline
set -o errtrace   # inherit ERR trap by functions, command subs, subshells 

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/CONFIG.sh"

# create package list
sudo dpkg --get-selections | sudo tee /root/pkglist.txt > /dev/null

BACKUP_DESTS=("${BACKUP_LOC}/server/borg")
BACKUP_SRCS=(/etc /home /root /usr/local /opt /var/lib /var/spool/cron/ /boot)
BACKUP_EXCL=(/var/lib/docker /var/lib/containers /var/cache /var/tmp)
BORG_FLAGS="--verbose --stats --show-rc"
BORG_PASS_FILE="${SCRIPT_DIR}/.borg-pass-server"
HEALTHCHECK_URL="$HCHK_SERVER_BACKUP"

source "${SCRIPT_DIR}/ping.sh"

on_error() {
    echo "❌ Backup failed."
    ping_fail || exit 1
}
trap on_error ERR

echo "----- 💾 Running server backup at $(date) ⏰ -----";

destargs=$( (( ${#BACKUP_DESTS[@]} == 0 )) || printf -- "-d %s " "${BACKUP_DESTS[@]}")
srcsargs=$( (( ${#BACKUP_SRCS[@]} == 0 ))  || printf -- "-s %s " "${BACKUP_SRCS[@]}")
exclargs=$( (( ${#BACKUP_EXCL[@]} == 0 ))  || printf -- "-e %s " "${BACKUP_EXCL[@]}")
/bin/bash -c "sudo ${SCRIPT_DIR}/borg-append.sh $srcsargs $destargs $exclargs -p $BORG_PASS_FILE -- ${BORG_FLAGS}"

ping_success || exit 1
