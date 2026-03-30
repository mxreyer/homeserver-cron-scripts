#!/bin/bash
# ==============================================================================
# Script Name: borg-append.sh
# Description: Append source files/dirs to (encrypted) borg repo.
#
# Usage: borg-append.sh -p backup_pass_file -d backup_dest_1 -d backup_dest_2 \
#                       -s source_1 -s vg/lv:source_2
#
# Sources are specified in one of the following formats:
#   -s /path/to/dir         plain source, no snapshot
#   -s vg/lv:/mount/point   we snapshot vg/lv first, then back up from snapshot to avoid
#                           file changes during backup creation
#
# Notes: Need to execute borg with sudo if the source files are owned by root.
#
# Preparation: Initialize the borg repo and create the corresponding passkey file (chmod 600).
# ==============================================================================

set -euo pipefail
set -o errtrace

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# === Parse arguments ===
BACKUP_SRCS=()
BACKUP_DESTS=()
BACKUP_EXCL=()
BORG_PASS_FILE=""
BORG_CHECK=""
LVM_SNAPSHOT_SIZE="5G"
LVM_SNAPSHOT_BASE_MOUNT="/mnt/borg-snapshot"

while getopts "s:d:e:p:cz:" opt; do
  case "$opt" in
    s) BACKUP_SRCS+=("$OPTARG") ;;
    d) BACKUP_DESTS+=("$OPTARG") ;;
    e) BACKUP_EXCL+=("$OPTARG") ;;
    p) BORG_PASS_FILE="$OPTARG" ;;
    c) BORG_CHECK="yes" ;;
    z) LVM_SNAPSHOT_SIZE="$OPTARG" ;;
  esac
done
shift $((OPTIND - 1))
BORG_FLAGS="$@"

# === Snapshot registry ===
# Tracks which VGs/LVs have been snapshotted to avoid duplicates.
# Associative array: [vg/lv] -> snapshot mount point
declare -A LVM_SNAPSHOTS  # vg/lv -> mount point

# === Error handling ===
cleanup() {
  unset BORG_PASSPHRASE
  for lv_key in "${!LVM_SNAPSHOTS[@]:-}"; do
    [[ -z "$lv_key" ]] && continue
    echo "🧹 Cleaning up LVM snapshot for ${lv_key}..."
    mount="${LVM_SNAPSHOTS[$lv_key]}"
    vg="${lv_key%%/*}"
    snapshot_name="borg-snapshot-${lv_key##*/}"
    umount "$mount" 2>/dev/null || true
    lvremove -f "/dev/${vg}/${snapshot_name}" 2>/dev/null || true
    echo "   removed snapshot for ${lv_key}"
  done
}
trap cleanup EXIT

on_error() {
  echo "❌ Appending to borg repo failed."
  exit 1
}
trap on_error ERR

# === Helper: parse source spec ===
# Returns 0 if lvm spec (vg/lv:/path), 1 if plain path
is_lvm_src() {
  [[ "$1" == */*:/* ]]
}

parse_lvm_src() {
  # Usage: parse_lvm_src "vg/lv:/path" -> sets SRC_VG, SRC_LV, SRC_PATH
  local spec="$1"
  local lv_part="${spec%%:*}"   # e.g. ubuntu-vg/home-lv
  SRC_PATH="${spec##*:}"        # e.g. /home
  SRC_VG="${lv_part%%/*}"       # e.g. ubuntu-vg
  SRC_LV="${lv_part##*/}"       # e.g. home-lv
}

# === Ensure snapshot exists for a given vg/lv, return its mount point ===
ensure_snapshot() {
  local vg="$1"
  local lv="$2"
  local key="${vg}/${lv}"
  local snapshot_name="borg-snapshot-${lv}"
  local mount="${LVM_SNAPSHOT_BASE_MOUNT}/${lv}"

  if [[ -n "${LVM_SNAPSHOTS[$key]+_}" ]]; then
    # Already snapshotted, reuse
    echo "   (reusing existing snapshot for ${key})"
    return 0
  fi

  echo "📸 Creating LVM snapshot of /dev/${vg}/${lv} (size: ${LVM_SNAPSHOT_SIZE})..."
  lvcreate -L"${LVM_SNAPSHOT_SIZE}" -s -n "${snapshot_name}" "/dev/${vg}/${lv}"
  mkdir -p "${mount}"
  mount -o ro "/dev/${vg}/${snapshot_name}" "${mount}"
  echo "   ✅ Mounted read-only at ${mount}"

  LVM_SNAPSHOTS["$key"]="$mount"
}

# === Check user input ===
if [[ ${#BACKUP_SRCS[@]} -eq 0 ]] || [[ ${#BACKUP_DESTS[@]} -eq 0 ]]; then
  echo "❌ Specify at least one source and destination for the backup!" >&2
  exit 1
fi
if [[ -z "$BORG_PASS_FILE" ]]; then
  echo "❌ Must specify passfile!" >&2
  exit 1
fi
if [[ ! -f "$BORG_PASS_FILE" ]]; then
  echo "❌ Couldn't find passfile: '${BORG_PASS_FILE}'" >&2
  exit 1
fi
read -r BORG_PASSPHRASE < "$BORG_PASS_FILE"

# Validate sources
for src in "${BACKUP_SRCS[@]}"; do
  if is_lvm_src "$src"; then
    parse_lvm_src "$src"
    if ! lvs "/dev/${SRC_VG}/${SRC_LV}" > /dev/null 2>&1; then
      echo "❌ Logical volume '/dev/${SRC_VG}/${SRC_LV}' not found." >&2
      exit 1
    fi
  else
    if [[ ! -e "$src" ]]; then
      echo "❌ Source '$src' is not a valid file or directory." >&2
      exit 1
    fi
  fi
done

# Validate destinations
for dest in "${BACKUP_DESTS[@]}"; do
  if ! sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg info "$dest" > /dev/null; then
    echo "❌ '$dest' is not a valid or accessible Borg repository." >&2
    exit 1
  fi
done

# === Create snapshots and build effective source list ===
EFFECTIVE_SRCS=()

for src in "${BACKUP_SRCS[@]}"; do
  if is_lvm_src "$src"; then
    parse_lvm_src "$src"
    ensure_snapshot "$SRC_VG" "$SRC_LV"
    snap_mount="${LVM_SNAPSHOTS[${SRC_VG}/${SRC_LV}]}"
    EFFECTIVE_SRCS+=("${snap_mount}${SRC_PATH}")
    echo "🔗 ${src} → ${snap_mount}${SRC_PATH}"
  else
    EFFECTIVE_SRCS+=("$src")
    echo "🔗 ${src} → ${src} (no snapshot)"
  fi
done

# === Script logic ===
echo ""
echo "🤖 Append to borg backup..."
echo "💾 Sources: ${EFFECTIVE_SRCS[*]}"
echo "👎 Exclude: ${BACKUP_EXCL[*]+"${BACKUP_EXCL[*]}"}"
echo "🗄️  Borg repos: ${BACKUP_DESTS[*]}"
echo "🏳️  Borg flags: $BORG_FLAGS"

for dest in "${BACKUP_DESTS[@]}"; do
  echo "➡️  Append to repo: ${dest}"
  if [[ "$BORG_CHECK" == "yes" ]]; then
    echo "borg check... ($(date))"
    sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg check --verify-data "$dest"
  else
    echo "skip borg check."
  fi
  echo "borg create... ($(date))"
  exclargs=$( (( ${#BACKUP_EXCL[@]} == 0 )) || printf -- "-e %s " "${BACKUP_EXCL[@]}")
  sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg create "$dest"::"{now}" "${EFFECTIVE_SRCS[@]}" $exclargs $BORG_FLAGS
  echo "borg prune... ($(date))"
  sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg prune --keep-daily=7 --keep-weekly=4 --keep-monthly=12 "$dest"
  echo "borg compact... ($(date))"
  sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg compact "$dest"
done

echo "✅ Successfully appended backups to borg repos."
