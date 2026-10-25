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
#   3. For plain sources, any nested mount points are also bind-mounted into
#      staging individually, so their contents are visible to borg.
#   4. cd into /tmp/borg-staging and run borg create from there, so paths are
#      stored as home/, mnt/photos/, mnt/videos/ and restore correctly.
#
# Notes: Need to execute borg with sudo if the source files are owned by root.
#        Snapshot names are derived from the LV name, so runs serialize on a lock
#        file: only one may be active at a time. A snapshot left behind by an
#        interrupted run (crash, power loss, kill) is detected and removed at the
#        start of the next run, since otherwise lvcreate keeps failing with
#        "Logical Volume ... already exists" until it is removed by hand.
#        The passphrase reaches borg via BORG_PASSCOMMAND, not BORG_PASSPHRASE:
#        sudo logs command-line environment assignments to syslog.
#
# Preparation: Initialize the borg repo and create the corresponding passkey file (chmod 600).
# ==============================================================================

set -euo pipefail
set -o errtrace

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/CONFIG.sh"

# === Parse arguments ===
BACKUP_SRCS=()
BACKUP_DESTS=()
BACKUP_EXCL=()
BORG_PASS_FILE=""
BORG_CHECK=""
#LVM_SNAPSHOT_PV="/dev/mmcblk0p1"         # should be configured in CONFIG.sh: eMMC PV to use
                                          # for snapshot allocation; must be added to the system
                                          # VG. To ensure it is not consumed by extending and LV,
                                          # we lock it after removing the snapshot.
                                          # leave variable empty to let LVM choose
LVM_SNAPSHOT_SIZE="10G"
LVM_SNAPSHOT_BASE="/mnt/borg-snapshots"   # where raw snapshots are mounted
STAGING_ROOT="/tmp/borg-staging"          # mirror of real fs structure for borg
LOCK_FILE="/run/lock/borg-append.lock"    # all runs share one snapshot name per LV,
                                          # so only one run may be active at a time
LOCK_WAIT="${BORG_APPEND_LOCK_WAIT:-3600}"  # seconds to wait for the lock before giving up

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

# === Helper: check if LVM_SNAPSHOT_PV is set (in CONFIG.sh!) and is a known PV ===
snapshot_pv_available() {
  [[ -n "${LVM_SNAPSHOT_PV:-}" ]] && pvs "$LVM_SNAPSHOT_PV" > /dev/null 2>&1
}

# === Helper: the snapshot LV name / device path we use for an origin LV ===
# The naming rule lives here alone, so creating and removing can never drift.
snapshot_name() { printf 'borg-snapshot-%s' "$1"; }
snapshot_dev()  { printf '/dev/%s/%s' "$1" "$(snapshot_name "$2")"; }

# === Helper: unmount everything backed by a device ===
# Covers the raw mount under LVM_SNAPSHOT_BASE as well as any bind mounts of it
# under STAGING_ROOT: a bind mount shares its source's major:minor, so mountinfo
# lists them all. Deepest first, so nested mounts go before their parents.
unmount_all_of_device() {
  local dev="$1" dm mm mp
  dm="$(readlink -f "$dev" 2>/dev/null)" || return 0
  [[ -b "$dm" ]] || return 0   # inactive LV: nothing can be mounted from it
  mm="$(lsblk -no MAJ:MIN "$dm" 2>/dev/null | tr -d '[:space:]')" || return 1
  [[ -n "$mm" ]] || return 1

  while IFS= read -r mp; do
    [[ -z "$mp" ]] && continue
    echo "   unmounting ${mp}..."
    umount "$mp" || { echo "❌ Could not unmount ${mp}." >&2; return 1; }
  done < <(awk -v m="$mm" '$3 == m {print $5}' /proc/self/mountinfo | tac)
}

# === Helper: make sure no borg snapshot of vg/lv exists ===
# Used for both jobs: clearing a snapshot left behind by an interrupted run, and
# tearing down our own on exit. Returns 0 if the snapshot is gone afterwards
# (including when there was none), 1 if something is still in the way.
drop_snapshot() {
  local vg="$1" lv="$2"
  local snap_dev origin=""
  snap_dev="$(snapshot_dev "$vg" "$lv")"

  lvs "$snap_dev" > /dev/null 2>&1 || return 0   # nothing there

  # Never remove anything that is not in fact a snapshot of the expected origin
  origin="$(lvs --noheadings -o origin "$snap_dev" 2>/dev/null | tr -d '[:space:]')" || origin=""
  if [[ "$origin" != "$lv" ]]; then
    echo "❌ ${snap_dev} is not a snapshot of ${lv} (origin: '${origin:-none}'); refusing to remove it." >&2
    return 1
  fi

  unmount_all_of_device "$snap_dev" || return 1
  lvremove -f "$snap_dev" || return 1
  echo "   removed snapshot ${snap_dev}"
}

# === Serialize runs ===
# Snapshot names are derived from the LV name alone, so two concurrent runs
# (e.g. the container backups overrunning into the server backup) would fight
# over the same snapshot. Take an exclusive lock for the whole run; it is
# released automatically when the process exits, however it exits.
# This has to happen before the EXIT trap is installed: a run that gives up
# here must not fire cleanup() and pull the snapshot PV, staging root and
# snapshots out from under the run that legitimately holds the lock.
exec 9>"$LOCK_FILE"
if ! flock -w "$LOCK_WAIT" 9; then
  echo "❌ Another borg-append.sh run holds ${LOCK_FILE}; gave up after ${LOCK_WAIT}s." >&2
  exit 1
fi

# === Error handling ===
cleanup() {
  # Unmount staging bind mounts in reverse order
  if [[ ${#STAGING_MOUNTS[@]} -gt 0 ]]; then
    echo "🧹 Unmounting staging bind mounts..."
    for (( i=${#STAGING_MOUNTS[@]}-1; i>=0; i-- )); do
      umount "${STAGING_MOUNTS[$i]}" 2>/dev/null || true
    done
  fi

  # Remove staging root
  if [[ -d "$STAGING_ROOT" ]]; then
    echo "🧹 Removing staging root..."
    rmdir --ignore-fail-on-non-empty "$STAGING_ROOT" 2>/dev/null || true
  fi

  # Unmount and remove LVM snapshots. Guarded, because a failure here must not
  # abort the trap before the PV is locked back down below.
  if [[ "${LVM_SNAPSHOTS[*]+var_is_set}" && "${#LVM_SNAPSHOTS[@]}" -gt 0 ]]; then
    echo "🧹 Removing LVM snapshots..."
    for lv_key in "${!LVM_SNAPSHOTS[@]}"; do
      if ! drop_snapshot "${lv_key%%/*}" "${lv_key##*/}"; then
        echo "   ⚠️  could not remove snapshot for ${lv_key} — next run will clean it up"
      fi
    done
  fi

  # Safety net: ensure snapshot PV allocation is locked down on any exit
  if snapshot_pv_available; then
    echo "🔒 Ensuring snapshot PV (${LVM_SNAPSHOT_PV}) allocation is disabled..."
    pvchange --allocatable n "$LVM_SNAPSHOT_PV" 2>/dev/null || true
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
  local snap_dev
  snap_dev="$(snapshot_dev "$vg" "$lv")"
  local snap_mount="${LVM_SNAPSHOT_BASE}/${lv}"

  if [[ -n "${LVM_SNAPSHOTS[$key]+_}" ]]; then
    return 0
  fi

  # A snapshot left behind by an interrupted run (crash, power loss, kill) makes
  # lvcreate fail on every later run until it is removed. We hold the run lock,
  # so anything still lying around here cannot belong to a live run.
  if lvs "$snap_dev" > /dev/null 2>&1; then
    echo "⚠️  Stale snapshot ${snap_dev} found — leftover from an interrupted run."
    drop_snapshot "$vg" "$lv"   # unguarded: the ERR trap aborts if it won't go
  fi

  # Register before creating, so cleanup() also tears down a half-built
  # snapshot when lvcreate or the mount below fails
  LVM_SNAPSHOTS["$key"]="$snap_mount"

  if snapshot_pv_available; then
    echo "🔓 Enabling allocation on snapshot PV (${LVM_SNAPSHOT_PV})..."
    pvchange --allocatable y "$LVM_SNAPSHOT_PV"
  fi

  echo "📸 Creating LVM snapshot of /dev/${vg}/${lv} (size: ${LVM_SNAPSHOT_SIZE})..."
  lvcreate -L"${LVM_SNAPSHOT_SIZE}" -s -n "$(snapshot_name "$lv")" "/dev/${vg}/${lv}" ${LVM_SNAPSHOT_PV:+"$LVM_SNAPSHOT_PV"}

  if snapshot_pv_available; then
    echo "🔒 Locking snapshot PV (${LVM_SNAPSHOT_PV}) allocation back down..."
    pvchange --allocatable n "$LVM_SNAPSHOT_PV"
  fi

  mkdir -p "${snap_mount}"
  mount -o ro "$snap_dev" "${snap_mount}"
  echo "   ✅ Mounted read-only at ${snap_mount}"

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
if [[ ! -s "$BORG_PASS_FILE" ]]; then
  echo "❌ Passfile is empty: '${BORG_PASS_FILE}'" >&2
  exit 1
fi

# Hand the passphrase to borg with BORG_PASSCOMMAND instead of
# BORG_PASSPHRASE="$(cat passfile)": sudo writes the environment assignments it
# is handed to syslog, so the latter puts the passphrase in the journal in
# plaintext for anyone who can read it. This way only the path of the (0600)
# passfile is logged. `head -n 1` matches how the passphrase was read before.
printf -v BORG_PASSCMD 'head -n 1 -- %q' "$BORG_PASS_FILE"

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
  if ! sudo BORG_PASSCOMMAND="$BORG_PASSCMD" borg info "$dest" > /dev/null; then
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

    # Also bind-mount any nested mount points individually, since a bind mount
    # of the parent only shows the empty underlying directory for nested mounts
    while IFS= read -r nested; do
      [[ -z "$nested" ]] && continue
      [[ "$nested" == "$src" ]] && continue # don't include the base dir
      [[ "$nested" == "$LVM_SNAPSHOT_BASE"* ]] && continue # don't include the snapshot base dir
      echo "   🔍 Found nested mount point: ${nested}"
      stage_path "$nested" "$nested"
    done < <(awk '{print $2}' /proc/mounts | grep "^${src}/" | sort || true)

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
    sudo BORG_PASSCOMMAND="$BORG_PASSCMD" borg check --verify-data "$dest"
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
  # Nested mount points under plain sources are bind-mounted individually
  # so their contents are visible to borg without needing --one-file-system.
  (
    cd "$STAGING_ROOT"
    sudo BORG_PASSCOMMAND="$BORG_PASSCMD" borg create \
      -v --stats --progress --show-rc \
      --list --filter=CE \
      "$dest"::"{now}" \
      "${STAGING_SRCS[@]}" \
      "${exclargs[@]+"${exclargs[@]}"}" \
      $BORG_FLAGS
  )

  echo "borg prune... ($(date))"
  sudo BORG_PASSCOMMAND="$BORG_PASSCMD" borg prune \
    --keep-daily=7 --keep-weekly=4 --keep-monthly=12 "$dest"
  echo "borg compact... ($(date))"
  sudo BORG_PASSCOMMAND="$BORG_PASSCMD" borg compact "$dest"
done

echo "✅ Successfully appended backups to borg repos."
