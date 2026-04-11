#!/bin/bash
# ==============================================================================
# Script Name: server-backup.sh
# Description : Back up server data via borg. Docker data is excluded.
#               Should be scheduled with cron, e.g.
#               0 3 * * * /bin/bash -c '<scriptdir>/pi-backup.sh >> <logs_dir>/pi-backup.log 2>&1'
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
ADD_SERVER_BACKUP_SOURCES="${ADD_SERVER_BACKUP_SOURCES:-}"
ADD_SERVER_BACKUP_EXCLSNS="${ADD_SERVER_BACKUP_EXCLSNS:-}"

# create package list
sudo dpkg --get-selections | sudo tee /root/pkglist.txt > /dev/null

BACKUP_DESTS=("${BACKUP_LOC}/server/borg" "${BACKUP_SSH}/server/borg")
if [[ -z $VG ]] || [[ -z $LV ]]; then
  BACKUP_SRCS=(/etc /home /root /usr/local /opt /var/lib /var/spool/cron/ /boot /mnt $ADD_SERVER_BACKUP_SOURCES)
else
  BACKUP_SRCS=($VG/$LV:/etc $VG/$LV:/home $VG/$LV:/root $VG/$LV:/usr/local $VG/$LV:/opt $VG/$LV:/var/lib $VG/$LV:/var/spool/cron/ $VG/$LV:/boot /mnt $ADD_SERVER_BACKUP_SOURCES)
fi
echo "backup sources: ${BACKUP_SRCS[@]}"
# note that /mnt/photos is the only subdir of /mnt under ubuntu-vg/pictures.
# Thus, we could do the following to separate /mnt/pictures from the rest and
# enable snapshotting for this subdir. However, we don't really need
# snapshotting, here.
# BACKUP_SRCS+=(ubuntu-vg/pictures:/mnt/photos)
# mapfile -t -O "${#BACKUP_SRCS[@]}" BACKUP_SRCS < <(find /mnt -mindepth 1 -maxdepth 1 ! -name 'photos')
# BACKUP_SRCS+=($ADD_SERVER_BACKUP_SOURCES)
BACKUP_EXCL=(/var/lib/docker /var/lib/containers /var/cache /var/tmp /mnt/backup $ADD_SERVER_BACKUP_EXCLSNS)
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
