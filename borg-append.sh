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
# Exclude format:
#   -e /path/to/exclude     Excluded paths are automatically remapped to snapshot
#                           mount points where applicable
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
  # Copy keys to a plain array first to avoid unbound variable errors
  # on empty associative arrays under set -u.
  lvm_keys=("${!LVM_SNAPSHOTS[@]:-}")
  for lv_key in "${lvm_keys[@]:-}"; do
    [[ -z "$lv_key" ]] && continue
    echo "🧹 Cleaning up LVM snapshot for ${lv_key}..."
    snap_mount="${LVM_SNAPSHOTS[$lv_key]}"
    vg="${lv_key%%/*}"
    snapshot_name="borg-snapshot-${lv_key##*/}"
    umount "$snap_mount" 2>/dev/null || true
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

# === Helper: test if a source spec is an LVM spec ===
is_lvm_src() {
  [[ "$1" == */*:/* ]]
}

# === Helper: parse "vg/lv:/path" into SRC_VG, SRC_LV, SRC_PATH ===
parse_lvm_src() {
  local spec="$1"
  local lv_part="${spec%%:*}"   # e.g. ubuntu-vg/home-lv
  SRC_PATH="${spec##*:}"        # e.g. /home
  SRC_VG="${lv_part%%/*}"       # e.g. ubuntu-vg
  SRC_LV="${lv_part##*/}"       # e.g. home-lv
}

# === Helper: create snapshot for vg/lv if not already done ===
ensure_snapshot() {
  local vg="$1"
  local lv="$2"
  local key="${vg}/${lv}"
  local snapshot_name="borg-snapshot-${lv}"
  local snap_mount="${LVM_SNAPSHOT_BASE_MOUNT}/${lv}"

  if [[ -n "${LVM_SNAPSHOTS[$key]+_}" ]]; then
    echo "   (reusing existing snapshot for ${key})"
    return 0
  fi

  echo "📸 Creating LVM snapshot of /dev/${vg}/${lv} (size: ${LVM_SNAPSHOT_SIZE})..."
  lvcreate -L"${LVM_SNAPSHOT_SIZE}" -s -n "${snapshot_name}" "/dev/${vg}/${lv}"
  mkdir -p "${snap_mount}"
  mount -o ro "/dev/${vg}/${snapshot_name}" "${snap_mount}"
  echo "   ✅ Mounted read-only at ${snap_mount}"

  LVM_SNAPSHOTS["$key"]="$snap_mount"
}

# === Helper: remap a path to its snapshot mount if it falls under an LVM source ===
# Sets REMAPPED_PATH. Returns 0 if remapped, 1 if not.
remap_path() {
  local path="$1"
  for src in "${BACKUP_SRCS[@]}"; do
    if is_lvm_src "$src"; then
      parse_lvm_src "$src"
      local key="${SRC_VG}/${SRC_LV}"
      if [[ -n "${LVM_SNAPSHOTS[$key]+_}" && "$path" == "${SRC_PATH}"* ]]; then
        local snap_mount="${LVM_SNAPSHOTS[$key]}"
        # Replace the original mount prefix with the snapshot mount prefix
        REMAPPED_PATH="${snap_mount}${path#${SRC_PATH}}"
        return 0
      fi
    fi
  done
  REMAPPED_PATH="$path"
  return 1
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

# === Remap exclude paths to snapshot mounts where applicable ===
EFFECTIVE_EXCL=()

excl_keys=("${BACKUP_EXCL[@]:-}")
for excl in "${excl_keys[@]:-}"; do
  [[ -z "$excl" ]] && continue
  if remap_path "$excl"; then
    echo "🔗 exclude ${excl} → ${REMAPPED_PATH}"
  fi
  EFFECTIVE_EXCL+=("$REMAPPED_PATH")
done

# === Script logic ===
echo ""
echo "🤖 Append to borg backup..."
echo "💾 Sources: ${EFFECTIVE_SRCS[*]}"
echo "👎 Exclude: ${EFFECTIVE_EXCL[*]+"${EFFECTIVE_EXCL[*]}"}"
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

  # Build exclude args as a proper array to handle paths with spaces
  exclargs=()
  excl_keys=("${EFFECTIVE_EXCL[@]:-}")
  for excl in "${excl_keys[@]:-}"; do
    [[ -z "$excl" ]] && continue
    exclargs+=(-e "$excl")
  done

  echo "borg create... ($(date))"
  sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg create \
    "$dest"::"{now}" \
    "${EFFECTIVE_SRCS[@]}" \
    "${exclargs[@]:-}" \
    $BORG_FLAGS
  echo "borg prune... ($(date))"
  sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg prune \
    --keep-daily=7 --keep-weekly=4 --keep-monthly=12 "$dest"
  echo "borg compact... ($(date))"
  sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg compact "$dest"
done

echo "✅ Successfully appended backups to borg repos."
