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
BORG_ACTION="$1"
if [[ -z "$BORG_ACTION" ]]; then
	echo "❌ No BORG_ACTION specified!"
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

for dir in beszel healthchecks immich mealie ollama paperless searxng stirling server; do

	echo "------------------"
	echo $dir
	echo "------------------"

	dirname=$(basename "$dir")
	dirpath=$(realpath "$dir")

	BORG_PASS_FILE=${SCRIPT_DIR}/.borg-pass-${dirname}
	read -r BORG_PASSPHRASE < "$BORG_PASS_FILE"

	repo="${dirpath}/borg"
	echo "repo: $repo"

	if [[ $BORG_ACTION != "init" ]]; then
	    latest=$(sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg list --short --last 1 "$repo")
	    if [ -z "$latest" ]; then
	        echo "No archives found in $repo"
	        exit 1
	    fi
	fi

	case "$BORG_ACTION" in 
	
	  "mount")
	    echo "mount..."
	    mnt="$BACKUP_LOC/tmp-borg-mounts/${dirname}"
	    [ -d "$mnt" ] || mkdir -p "$mnt"
	    echo "archive: " "$repo"::"$latest"
	    echo "mountpoint: ${mnt}"
	    sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg mount "$repo"::"$latest" ${mnt}
	    ;;
	
	  "unmount"|"umount") 
	    echo "unmount..."
	    mnt="$BACKUP_LOC/tmp-borg-mounts/${dirname}"
	    sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg umount ${mnt}
	    ;;
	
	  "list") 
	    echo "list..."
	    sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg list "$repo"::"$latest" --format="{mode} {user} {group} {path}{NL}"
	    #sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg list --last 1 --format "{archive} {time}\n" "$repo"
	    ;;
	  
    	  "init") 
	    echo "init..."
	    [ -d "$repo" ] || mkdir -p "$repo"
	    echo "repo"
	    ls "$repo"
	    BORG_PASSPHRASE="$BORG_PASSPHRASE" borg init --encryption=repokey "$repo"
	    borg key export "$repo"
	    ;;
	  
    	  "extract") 
            echo "extract..."
            [ -d "$DOCKER_BINDS_DIR" ] || mkdir "$DOCKER_BINDS_DIR"
	    (cd /; sudo BORG_PASSPHRASE="$BORG_PASSPHRASE" borg extract \
		    "$repo"::"$latest")
	    ;; 
	
	  "extract-exclude-sidecars") 
            echo "extract (without tailscale/caddy sidecar volumes)..."
            [ -d "$DOCKER_BINDS_DIR" ] || mkdir "$DOCKER_BINDS_DIR"
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
