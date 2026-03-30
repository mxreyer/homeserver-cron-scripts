#!/bin/bash
# ==============================================================================
# Script Name: borg-action.sh
# Description: mount, unmount, initialize, list, or extract borg repos for all
#              my docker containers.
#
# Preparation: Initialize password files .borg-pass-XXX (chmod 600)
# ==============================================================================

set -euo pipefail # exit on error, undef vars, or failed pipeline
set -o errtrace   # inherit ERR trap by functions, command subs, subshells 

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/CONFIG.sh"

# === Parse arguments == #
BORG_MOUNT_BASE="$PWD"
BORG_ACTION=""
BASE_DIR="$PWD"       # note: this can also be a remote dir, like user@server:/mnt/backup/remote-server
BORG_REPOS=""         # one or more borg repos.
BORG_ARCHIVE="latest" # the archive within the repo. defaults to latest.
while getopts "m:a:d:r:x:" opt; do
  case "$opt" in
    a) BORG_ACTION="$OPTARG" ;;
    m) BORG_MOUNT_BASE="$OPTARG" ;;
    d) BASE_DIR="$OPTARG" ;;
    r) BORG_REPOS="$OPTARG" ;;
    x) BORG_ARCHIVE="$OPTARG" ;;
  esac
done

# === traps and error handling === #

on_exit() {
  unset BORG_PASSPHRASE # for security, unset passphrase
}
trap on_exit EXIT

on_error() {
  echo "❌ Performing borg action \"${BORG_ACTION}\" failed."
  exit 1
}
trap on_error ERR

# === check and confirm user input === #
if [[ -f "$BASE_DIR" ]]; then
  echo "❌ BASE_DIR is not a valid dir!"
  exit 1
fi

if [[ -z "$BORG_ACTION" ]]; then
  echo "❌ No BORG_ACTION specified via -a!"
  exit 1
fi

if [[ -z "$BORG_REPOS" ]]; then
  echo "❌ No BORG_REPOS specified via -r!"
  exit 1
fi

confirm=""
read -p "Execute BORG_ACTION: ${BORG_ACTION}? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
  echo "🛑 Operation cancelled."
  exit 1
fi

confirm=""
if [[ "$BORG_ACTION" = extract* ]] || [[ "$BORG_ACTION" = delete ]] ; then
  read -p "🚨 Really perform BORG_ACTION: ${BORG_ACTION}? This may/will delete data! (yes/no): " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "🛑 Operation cancelled."
    exit 1
  fi
fi

# === script logic === #

#[[ -z "$BORG_REPOS" ]] && BORG_REPOS="beszel immich mealie ollama paperless searxng stirling server" healthchecks 
for repo in $BORG_REPOS; do

  echo "------------------"
  echo $repo
  echo "------------------"

  repopath="${BASE_DIR}/${repo}/borg"
  echo "📁 repopath: $repopath"

  BORG_PASS_FILE=${SCRIPT_DIR}/.borg-pass-${repo}
  read -r BORG_PASSPHRASE < "$BORG_PASS_FILE"

  if [[ $BORG_ARCHIVE == latest ]] && [[ ! $BORG_ACTION =~ (init|list|umount|unmount|delete) ]]; then
    echo "ℹ️  No archive name provided. 🔎 Find latest archive..."
    BORG_ARCHIVE=$(sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg list --short --last 1 "$repopath")
    if [[ -z "$BORG_ARCHIVE" ]]; then
      echo "❌ No archives found in $repopath"
      exit 1
    fi
    echo "👍 ... found latest=$BORG_ARCHIVE"
  fi

  #if [[ "$BORG_ACTION" == *mount ]] && [[ -z "$BORG_MOUNT_BASE" ]]; then
  #  echo "❌ No BORG_MOUNTPOINT specified via -m!"
  #  exit 1
  #fi

  if [[ "$BORG_ACTION" == extract* ]]; then
    [[ -d "$DOCKER_BINDS_DIR" ]] || mkdir "$DOCKER_BINDS_DIR"
  fi
  
  if [[ "$BORG_ACTION" == *mount ]]; then
    BORG_MOUNTPOINT="${BORG_MOUNT_BASE}/${repo}-backup-mount"
  fi

  case "$BORG_ACTION" in 

    "mount")
      echo "mount..."
      #[[ -d "$BORG_MOUNTPOINT" ]] || mkdir -p "$BORG_MOUNTPOINT"
      if [[ -d "$BORG_MOUNTPOINT" ]]; then
        echo "mountpoint $BORG_MOUNTPOINT already exists. exit"
      else
        mkdir -p "$BORG_MOUNTPOINT"
      fi
      echo "archive: " "$repopath"::"$BORG_ARCHIVE"
      echo "mountpoint: ${BORG_MOUNTPOINT}"
      sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg mount "$repopath"::"$BORG_ARCHIVE" ${BORG_MOUNTPOINT}
      ;;

    "unmount"|"umount") 
      echo "unmount..."
      sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg umount ${BORG_MOUNTPOINT}
      rmdir "$BORG_MOUNTPOINT"
      ;;

    "list-archive") 
      echo "list archive..."
      sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg list "$repopath"::"$BORG_ARCHIVE" --format="{mode} {user} {group} {path}{NL}"
      ;;

    "list") 
      echo "list..."
      sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg list --format "{archive} {time} {NL}" "$repopath"
      ;;

    "init") 
      echo "init..."
      BORG_PASSPHRASE="$BORG_PASSPHRASE" borg init --encryption=repokey "$repopath"
      borg key export "$repopath"
      ;;
    
    "delete") 
      echo "delete..."
      sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg delete "$repopath"::"$BORG_ARCHIVE"
      ;;

    "extract") 
      echo "extract..."
      (cd /; sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg extract \
        "$repopath"::"$BORG_ARCHIVE")
      ;;

    "extract-exclude-sidecars") 
      echo "extract (without tailscale/caddy sidecar volumes)..."
      (cd /; sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg extract \
        --exclude='*tailscale*' --exclude='*caddy*' \
        "$repopath"::"$BORG_ARCHIVE")
      ;; 

    *) 
      echo "Unknown BORG_ACTION: ${BORG_ACTION}"
      exit 1
      ;; 
  esac        
done
