#!/bin/bash
# ==============================================================================
# Script Name: pi-clone.sh
# Description : Clones the pi server's disk to an external hard drive so that
#               it can quickly be brought back in case of desaster. Should be
#               scheduled with cron, e.g.
#               0 3 * * 1 /bin/bash -c '<scriptdir>/pi-clone.sh >> <logs_dir>/logs/pi-clone.log 2>&1'
# Notes:
#     - Prior to the first run, the target disk should be initialized by running rpi-clone w/o -u flag.
#     - In case extra data partitions on the target disk are desired, check
#       https://github.com/geerlingguy/rpi-clone?tab=readme-ov-file#7-clone-sd-card-to-usb-disk-with-extra-partitions 
# ==============================================================================

set -euo pipefail # exit on error, undef vars, or failed pipeline
set -o errtrace   # inherit ERR trap by functions, command subs, subshells 

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/CONFIG.sh"

# === Configuration === #
BACKUP_DRIVE="/dev/sdc" # target device for cloning
PTUUID_EXPECTED="52d2c54f" # PTUUID of target drive to make sure we write to the correct device (sudo blkid /dev/sdc)
HEALTHCHECK_URL="$HCHK_PI4_CLONE" # healthcheck ping url

tmp_docker_file=$(mktemp)
tmp_mnt=$(mktemp -d)
source "${SCRIPT_DIR}/container-handler.sh" || exit 1
source "${SCRIPT_DIR}/ping.sh"

# === Traps, error handling === #
on_exit() {
  start_docker || exit 1
  (mountpoint -q "$tmp_mnt") && sudo umount "$tmp_mnt"
  rm -rf "$tmp_docker_file" "$tmp_mnt"
}
trap on_exit EXIT

on_error() {
  echo "❌ Clone failed."
  ping_fail || exit 1
}
trap on_error ERR

# === Script logic === #

echo "----- 💾 Cloning server disk at $(date) ⏰ -----";

stop_docker || exit 1

echo "🐑 🐑 Cloning Pi drive to ${BACKUP_DRIVE} with ptuuid ${PTUUID_EXPECTED} 💾 💾"

if sudo /usr/sbin/blkid "$BACKUP_DRIVE" | grep -q ".*${PTUUID_EXPECTED}.*"; then
  echo "✅ Backup drive UUID matches. Proceeding..."
else
  echo "❌ UUID mismatch. Aborting!"
  exit 1
fi

shopt -s dotglob nullglob  # include dotfiles; handle empty dirs safely

(mountpoint -q "$tmp_mnt") || sudo mount "${BACKUP_DRIVE}1" "$tmp_mnt"
echo "${BACKUP_DRIVE}1 is mounted at $tmp_mnt"
echo "remove ${tmp_mnt}/*"
sudo rm -rf ${tmp_mnt}/*

echo "execute rpi-clone..."
sudo rpi-clone -u $(basename $BACKUP_DRIVE)

(mountpoint -q "$tmp_mnt") || sudo mount "${BACKUP_DRIVE}1" "$tmp_mnt"
echo "${BACKUP_DRIVE}1 is mounted at $tmp_mnt"
echo "To temporarily disable boot, moved ${tmp_mnt}/* to ${tmp_mnt}/rm-this-dir-lvl-to-boot/*."
echo "NOTE: To re-enable boot, you have to manually move all files (including dotfiles!) from bootfs/rm-this-dir-lvl-to-boot/ back to bootfs/!"
sudo mkdir -p ${tmp_mnt}/rm-this-dir-lvl-to-boot/
for f in ${tmp_mnt}/*; do
  [[ "$f" == "${tmp_mnt}/rm-this-dir-lvl-to-boot" ]] && continue
  sudo mv -- "$f" "${tmp_mnt}/rm-this-dir-lvl-to-boot"
done

ping_success || exit 1

echo "✅ Cloning Pi complete."
