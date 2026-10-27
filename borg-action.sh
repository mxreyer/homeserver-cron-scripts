#!/bin/bash
# ==============================================================================
# Script Name: borg-action.sh
# Description: mount, unmount, initialize, list, compact, or extract borg repos for all
#              my docker containers.
#
# Preparation: Initialize password files .borg-pass-XXX (chmod 600)
#
# Notes: The passphrase reaches borg via BORG_PASSCOMMAND, not BORG_PASSPHRASE:
#        sudo logs command-line environment assignments to syslog.
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
if [[ "$BORG_ACTION" = extract* ]]; then
  read -p "🚨 Really perform BORG_ACTION: ${BORG_ACTION}? This may overwrite/delete data! (yes/no): " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "🛑 Operation cancelled."
    exit 1
  fi
fi

confirm=""
if [[ "$BORG_ACTION" = delete ]] ; then
  read -p "🚨 Really perform BORG_ACTION: ${BORG_ACTION}? (yes/no): " confirm
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
  if [[ ! -s "$BORG_PASS_FILE" ]]; then
    echo "❌ Missing or empty passfile: '${BORG_PASS_FILE}'" >&2
    exit 1
  fi

  # Hand the passphrase to borg with BORG_PASSCOMMAND instead of
  # BORG_PASSPHRASE="$(cat passfile)": sudo writes the environment assignments
  # it is handed to syslog, so the latter puts the passphrase in the journal in
  # plaintext for anyone who can read it. This way only the path of the (0600)
  # passfile is logged. `head -n 1` matches how the passphrase was read before.
  printf -v BORG_PASSCMD 'head -n 1 -- %q' "$BORG_PASS_FILE"

  # resolve "latest" per repo: archive names differ between repos
  archive="$BORG_ARCHIVE"
  if [[ $archive == latest ]] && [[ ! $BORG_ACTION =~ (init|list|compact|umount|unmount|delete) ]]; then
    echo "ℹ️  No archive name provided. 🔎 Find latest archive..."
    archive=$(sudo BORG_PASSCOMMAND="$BORG_PASSCMD" borg list --short --last 1 "$repopath")
    if [[ -z "$archive" ]]; then
      echo "❌ No archives found in $repopath"
      exit 1
    fi
    echo "👍 ... found latest=$archive"
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
      echo "archive: " "$repopath"::"$archive"
      echo "mountpoint: ${BORG_MOUNTPOINT}"
      sudo BORG_PASSCOMMAND="$BORG_PASSCMD" borg mount "$repopath"::"$archive" ${BORG_MOUNTPOINT}
      ;;

    "unmount"|"umount") 
      echo "unmount..."
      sudo BORG_PASSCOMMAND="$BORG_PASSCMD" borg umount ${BORG_MOUNTPOINT}
      rmdir "$BORG_MOUNTPOINT"
      ;;

    "list-archive") 
      echo "list archive..."
      sudo BORG_PASSCOMMAND="$BORG_PASSCMD" borg list "$repopath"::"$archive" --format="{mode} {user} {group} {path}{NL}"
      ;;

    "list") 
      echo "list..."
      sudo BORG_PASSCOMMAND="$BORG_PASSCMD" borg list --format "{archive} {time} {NL}" "$repopath"
      ;;

    "compact") 
      echo "compact..."
      sudo BORG_PASSCOMMAND="$BORG_PASSCMD" borg compact "$repopath"
      ;;

    "init") 
      echo "init..."
      # init needs BORG_NEW_PASSPHRASE: it picks the passphrase via
      # Passphrase.new(), which reads BORG_NEW_PASSPHRASE and BORG_PASSPHRASE
      # but not BORG_PASSCOMMAND, and would otherwise prompt. There is no sudo
      # on this line, so the assignment is not written to the journal.
      BORG_NEW_PASSPHRASE="$(head -n 1 -- "$BORG_PASS_FILE")" borg init --encryption=repokey "$repopath"
      borg key export "$repopath"
      ;;
    
    "delete") 
      echo "delete..."
      sudo BORG_PASSCOMMAND="$BORG_PASSCMD" borg delete "$repopath"::"$archive"
      ;;

    "extract") 
      echo "extract..."
      (cd /; sudo BORG_PASSCOMMAND="$BORG_PASSCMD" borg extract \
        "$repopath"::"$archive")
      ;;

    "extract-exclude-sidecars") 
      echo "extract (without tailscale/caddy sidecar volumes)..."
      (cd /; sudo BORG_PASSCOMMAND="$BORG_PASSCMD" borg extract \
        --exclude='*tailscale*' --exclude='*caddy*' \
        "$repopath"::"$archive")
      ;; 

    *) 
      echo "Unknown BORG_ACTION: ${BORG_ACTION}"
      exit 1
      ;; 
  esac        
done
