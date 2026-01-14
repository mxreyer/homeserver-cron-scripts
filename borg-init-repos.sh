#!/bin/bash
# ==============================================================================
# Script Name: borg-init-repos.sh
# Description: Initializes encrypted borg repos, prints repo keys
#
# Usage: Execute ./borg-init-repos.sh, then copy and save repo keys 
#
# Notes:
#
# Preparation: Initialize password files .borg-pass-XXX (chmod 600)
# ==============================================================================

set -euo pipefail # exit on error, undef vars, or failed pipeline
set -o errtrace   # inherit ERR trap by functions, command subs, subshells 

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

on_exit() {
    unset BORG_PASSPHRASE # for security, unset passphrase
}
trap on_exit EXIT

on_error() {
    echo "❌ Initializing borg repos failed."
    exit 1
}
trap on_error ERR

for dir in beszel healthchecks immich mealie ollama paperless searxng stirling server; do

	echo '------------------------------------'
	echo $dir
	echo '------------------------------------'

	[[ -d "$dir" ]] || mkdir "$dir"

	dirname=$(basename "$dir")
	dirpath=$(realpath "$dir")

	BORG_PASS_FILE=${SCRIPT_DIR}/.borg-pass-${dirname}
	read -r BORG_PASSPHRASE < "$BORG_PASS_FILE"

	repo="${dirpath}/borg"

	BORG_PASSPHRASE="$BORG_PASSPHRASE" borg init --encryption=repokey "$repo"
	borg key export "$repo"
done
