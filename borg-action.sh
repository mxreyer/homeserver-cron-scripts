#!/bin/bash
# ==============================================================================
# Script Name: borg-action.sh
# Description: mount, unmount, initialize, list, or extract borg repos for all
#              my docker containers.
# ==============================================================================

set -euo pipefail # exit on error, undef vars, or failed pipeline
set -o errtrace   # inherit ERR trap by functions, command subs, subshells 

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/CONFIG.sh"

# === Parse arguments == #
BORG_MOUNTPOINT="" #"$BACKUP_LOC/tmp-borg-mounts/${dirname}"
BORG_ACTION=""
BASE_DIR="$PWD"
while getopts "m:a:d:" opt; do
  case "$opt" in
    a) BORG_ACTION="$OPTARG" ;;
    m) BORG_MOUNTPOINT="$OPTARG" ;;
    d) BASE_DIR="$OPTARG" ;;
  esac
done

# === traps and error handling === #

on_exit() {
  unset BORG_PASSPHRASE # for security, unset passphrase
}
trap on_exit EXIT

on_error() {
  echo "❌ Mounting borg repos failed."
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

confirm=""
read -p "Execute BORG_ACTION: ${BORG_ACTION}? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
  echo "Operation cancelled."
  exit 1
fi

confirm=""
if [[ "$BORG_ACTION" = extract* ]]; then
  read -p "Really perform BORG_ACTION: ${BORG_ACTION}? This may delete data! (yes/no): " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "Operation cancelled."
    exit 1
  fi
fi

# === script logic === #

#for dir in beszel healthchecks immich mealie ollama paperless searxng stirling server; do
for dir in server; do

  echo "------------------"
  echo $dir
  echo "------------------"

  dirpath="${BASE_DIR}/${dir}"
  dirname=$(basename "$dirpath")

  BORG_PASS_FILE=${SCRIPT_DIR}/.borg-pass-${dirname}
  read -r BORG_PASSPHRASE < "$BORG_PASS_FILE"

  repo="${dirpath}/borg"
  echo "repo: $repo"

  if [[ $BORG_ACTION != "init" ]]; then
    latest=$(sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg list --short --last 1 "$repo")
    if [[ -z "$latest" ]]; then
      echo "No archives found in $repo"
      exit 1
    fi
  fi

  if [[ "$BORG_ACTION" == *mount ]] && [[ -z "$BORG_MOUNTPOINT" ]]; then
    echo "❌ No BORG_MOUNTPOINT specified via -m!"
    exit 1
  fi

  if [[ "$BORG_ACTION" == extract* ]]; then
    [[ -d "$DOCKER_BINDS_DIR" ]] || mkdir "$DOCKER_BINDS_DIR"
  fi

  case "$BORG_ACTION" in 

    "mount")
      echo "mount..."
      [[ -d "$BORG_MOUNTPOINT" ]] || mkdir -p "$BORG_MOUNTPOINT"
      echo "archive: " "$repo"::"$latest"
      echo "mountpoint: ${BORG_MOUNTPOINT}"
      sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg mount "$repo"::"$latest" ${BORG_MOUNTPOINT}
      ;;

    "unmount"|"umount") 
      echo "unmount..."
      sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg umount ${BORG_MOUNTPOINT}
      ;;

    "list") 
      echo "list..."
      sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg list "$repo"::"$latest" --format="{mode} {user} {group} {path}{NL}"
      #sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg list --last 1 --format "{archive} {time}\n" "$repo"
      ;;

    "init") 
      echo "init..."
      [[ -d "$repo" ]] || mkdir -p "$repo"
      echo "repo"
      ls "$repo"
      BORG_PASSPHRASE="$BORG_PASSPHRASE" borg init --encryption=repokey "$repo"
      borg key export "$repo"
      ;;

    "extract") 
      echo "extract..."
      (cd /; sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg extract \
        "$repo"::"$latest")
      ;;

    "extract-exclude-sidecars") 
      echo "extract (without tailscale/caddy sidecar volumes)..."
      (cd /; sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg extract \
        --exclude='*tailscale*' --exclude='*caddy*' \
        "$repo"::"$latest")
      ;; 

    *) 
      echo "Unknown BORG_ACTION: ${BORG_ACTION}"
      exit 1
      ;; 
  esac        
done
