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
#   -e /path/to/exclude     Excluded paths are automatically remapped into the
#                           staging root where applicable
#
# How it works:
#   1. For each LVM source spec, create a snapshot and mount it read-only
#   2. Build a staging root under /tmp/borg-staging that mirrors the real
#      filesystem structure using bind mounts:
#        /tmp/borg-staging/home        -> snapshot of ubuntu-vg/ubuntu-lv at /home
#        /tmp/borg-staging/mnt/photos  -> snapshot of ubuntu-vg/pictures at /mnt/photos
#        /tmp/borg-staging/mnt/videos  -> bind mount of /mnt/videos (no snapshot)
#   3. cd into /tmp/borg-staging and run borg create from there, so paths are
#      stored as home/, mnt/photos/, mnt/videos/ and restore correctly.
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
LVM_SNAPSHOT_BASE="/mnt/borg-snapshots"   # where raw snapshots are mounted
STAGING_ROOT="/tmp/borg-staging"          # mirror of real fs structure for borg

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

# === Registries ===
declare -A LVM_SNAPSHOTS   # [vg/lv] -> raw snapshot mount point
STAGING_MOUNTS=()          # all bind mounts under STAGING_ROOT, for cleanup

# === Error handling ===
cleanup() {
  trap - ERR
  unset BORG_PASSPHRASE

  # Unmount staging bind mounts in reverse order
  if [[ ${#STAGING_MOUNTS[@]} -gt 0 ]]; then
    echo "🧹 Unmounting staging bind mounts..."
    for (( i=${#STAGING_MOUNTS[@]}-1; i>=0; i-- )); do
      umount "${STAGING_MOUNTS[$i]}" 2>/dev/null || true
    done
  fi

  # Remove staging root
  if [[ -d "$STAGING_ROOT" ]]; then
    rmdir --ignore-fail-on-non-empty "$STAGING_ROOT" 2>/dev/null || true
  fi

  # Unmount and remove LVM snapshots
  if [[ -v LVM_SNAPSHOTS && ${#LVM_SNAPSHOTS[@]} -gt 0 ]]; then
    echo "🧹 Removing LVM snapshots..."
    for lv_key in "${!LVM_SNAPSHOTS[@]}"; do
      snap_mount="${LVM_SNAPSHOTS[$lv_key]}"
      vg="${lv_key%%/*}"
      snapshot_name="borg-snapshot-${lv_key##*/}"
      umount "$snap_mount" 2>/dev/null || true
      lvremove -f "/dev/${vg}/${snapshot_name}" 2>/dev/null || true
      echo "   removed snapshot for ${lv_key}"
    done
  fi
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
  local lv_part="${spec%%:*}"
  SRC_PATH="${spec##*:}"
  SRC_VG="${lv_part%%/*}"
  SRC_LV="${lv_part##*/}"
}

# === Helper: create LVM snapshot if not already done ===
ensure_snapshot() {
  local vg="$1"
  local lv="$2"
  local key="${vg}/${lv}"
  local snapshot_name="borg-snapshot-${lv}"
  local snap_mount="${LVM_SNAPSHOT_BASE}/${lv}"

  if [[ -n "${LVM_SNAPSHOTS[$key]+_}" ]]; then
    #echo "   (reusing existing snapshot for ${key})"
    return 0
  fi

  echo "📸 Creating LVM snapshot of /dev/${vg}/${lv} (size: ${LVM_SNAPSHOT_SIZE})..."
  lvcreate -L"${LVM_SNAPSHOT_SIZE}" -s -n "${snapshot_name}" "/dev/${vg}/${lv}"
  mkdir -p "${snap_mount}"
  mount -o ro "/dev/${vg}/${snapshot_name}" "${snap_mount}"
  echo "   ✅ Mounted read-only at ${snap_mount}"

  LVM_SNAPSHOTS["$key"]="$snap_mount"

  # Auto-exclude the raw snapshot mount point so it isn't picked up
  # if a plain source covers its parent directory
  BACKUP_EXCL+=("$snap_mount")
  echo "   🙅 Auto-excluded raw snapshot mount ${snap_mount}"
}

# === Helper: bind-mount src into staging root, mirroring the real path ===
stage_path() {
  local src="$1"           # real or snapshot path to bind-mount
  local logical_path="$2"  # the logical path this represents (e.g. /home)

  # Strip leading slash to get relative path, then construct staging target
  local rel_path="${logical_path#/}"
  local staging_target="${STAGING_ROOT}/${rel_path}"

  mkdir -p "$staging_target"
  mount --bind "$src" "$staging_target"
  STAGING_MOUNTS+=("$staging_target")
  echo "   📂 staged ${logical_path} → ${staging_target}"
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

# === Create snapshots and build staging root ===
echo "🏗️  Building staging root at ${STAGING_ROOT}..."
mkdir -p "$STAGING_ROOT"

STAGING_SRCS=()  # relative paths under STAGING_ROOT to pass to borg

for src in "${BACKUP_SRCS[@]}"; do
  if is_lvm_src "$src"; then
    parse_lvm_src "$src"
    ensure_snapshot "$SRC_VG" "$SRC_LV"
    snap_mount="${LVM_SNAPSHOTS[${SRC_VG}/${SRC_LV}]}"
    # Bind-mount the snapshot subdir into staging, mirroring the logical path
    stage_path "${snap_mount}${SRC_PATH}" "$SRC_PATH"
  else
    # Plain source: bind-mount the real path into staging
    stage_path "$src" "$src"
  fi
  # Record the relative staging path for borg (strip leading slash)
  rel="${src##*:}"   # for LVM specs, take the path part; for plain, use as-is
  STAGING_SRCS+=("${rel#/}")
done

# === Remap exclude paths into staging root ===
EFFECTIVE_EXCL=()
if [[ ${#BACKUP_EXCL[@]} -gt 0 ]]; then
  for excl in "${BACKUP_EXCL[@]}"; do
    # Strip leading slash — excludes are relative to STAGING_ROOT
    EFFECTIVE_EXCL+=("${excl#/}")
  done
fi

# === Script logic ===
echo ""
echo "🤖 Append to borg backup..."
echo "💾 Staging sources: ${STAGING_SRCS[*]}"
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

  exclargs=()
  if [[ ${#EFFECTIVE_EXCL[@]} -gt 0 ]]; then
    for excl in "${EFFECTIVE_EXCL[@]}"; do
      exclargs+=(-e "$excl")
    done
  fi

  echo "borg create... ($(date))"
  # cd into staging root so borg stores paths as home/, mnt/photos/ etc.
  # and they restore correctly to /home, /mnt/photos etc.
  # --one-file-system prevents borg from crossing bind mount boundaries,
  # ensuring each staged source is backed up exactly once.
  (
    cd "$STAGING_ROOT"
    sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg create \
      --one-file-system \
      "$dest"::"{now}" \
      "${STAGING_SRCS[@]}" \
      "${exclargs[@]+"${exclargs[@]}"}" \
      $BORG_FLAGS
  )

  echo "borg prune... ($(date))"
  sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg prune \
    --keep-daily=7 --keep-weekly=4 --keep-monthly=12 "$dest"
  echo "borg compact... ($(date))"
  sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg compact "$dest"
done

echo "✅ Successfully appended backups to borg repos."
