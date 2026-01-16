#!/bin/bash
# ==============================================================================
# Script Name: docker-service-backup.sh
# Description: Master script providing functionality to back up persistent
#              docker container data via borg
# ==============================================================================

set -euo pipefail
set -o errtrace

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmpdir=$(mktemp -d)

# === Parse arguments == #
HEALTHCHECK_URL=""
COMPOSE_FILE=""
STOP_CONTAINERS_PRE=() # containers to be stopped BEFORE running PREP_SCRIPT
	               # if none specified, no containers are stopped
STOP_CONTAINERS=()     # containers to be stopped AFTER running PREP_SCRIPT
	               # if none specified, all containers are stopped
BACKUP_SRCS=()
BACKUP_DESTS=()
BACKUP_EXCL=()
BORG_PASS_FILE=""
BORG_FLAGS=""
PREP_SCRIPT=""
while getopts "u:s:d:e:p:f:y:C:c:i:" opt; do
  case "$opt" in
    u) HEALTHCHECK_URL="$OPTARG" ;;
    s) BACKUP_SRCS+=("$OPTARG") ;;
    d) BACKUP_DESTS+=("$OPTARG") ;;
    e) BACKUP_EXCL+=("$OPTARG") ;;
    p) BORG_PASS_FILE="$OPTARG" ;;
    f) BORG_FLAGS="$OPTARG" ;;
    y) COMPOSE_FILE="$OPTARG" ;;
    C) STOP_CONTAINERS_PRE+=("$OPTARG") ;;
    c) STOP_CONTAINERS+=("$OPTARG") ;;
    i) PREP_SCRIPT=("$OPTARG") ;;
  esac
done
shift $((OPTIND - 1))
REMAINING_ARGS="$@";

# === Check user input === #
if [[ ! -z $REMAINING_ARGS ]]; then
  echo "❌ Extra arguments: '${REMAINING_ARGS}'" >&2  
  exit 1
fi
if [[ ! -z "$COMPOSE_FILE" ]] &&  [[ ! -f $COMPOSE_FILE ]]; then
  echo "❌ Couldn't find compose file: '${COMPOSE_FILE}'" >&2  
  exit 1
fi
if [[ ! -z "$PREP_SCRIPT" ]] &&  [[ ! -f $PREP_SCRIPT ]]; then
  echo "❌ Couldn't find prep script: '${PREP_SCRIPT}'" >&2  
  exit 1
fi

# === Stop and Start docker containers === #
stop_docker_pre() {
  if [[ ! -z "$COMPOSE_FILE" ]] && [[ ! -z "${STOP_CONTAINERS_PRE[@]}" ]]; then
    echo "🐳 Stopping containers (pre prep script)..."
    docker compose -f "$COMPOSE_FILE" stop "${STOP_CONTAINERS_PRE[@]}"
  fi
}
stop_docker() {
  if [[ ! -z "$COMPOSE_FILE" ]]; then
    echo "🐳 Stopping containers (post prep script)..."
    docker compose -f "$COMPOSE_FILE" stop "${STOP_CONTAINERS[@]}"
  fi
}
start_docker() {
  if [[ ! -z "$COMPOSE_FILE" ]]; then
    echo "🐳 Starting containers..."
    docker compose -f "$COMPOSE_FILE" start "${STOP_CONTAINERS_PRE[@]}" "${STOP_CONTAINERS[@]}"
  fi
}

# === Traps, error handling === #
on_exit() {
  rm -rf "$tmpdir"
  start_docker
}
trap on_exit EXIT

on_error() {
  echo "❌ Backup failed. 🐳 Restart docker containers, 🛜 ping failure."
  ping_fail || exit 1
}
trap on_error ERR

# === Script logic === #

echo "----- 💾 Running docker service backup at $(date) ⏰ -----";

source "${SCRIPT_DIR}/ping.sh"

stop_docker_pre

if [[ -f "$PREP_SCRIPT" ]]; then
  echo "👾 Running prep script..."
  "$PREP_SCRIPT" # run preparation script (like db dumps etc)
fi

stop_docker

destargs=$( (( ${#BACKUP_DESTS[@]} == 0 )) || printf -- "-d %s " "${BACKUP_DESTS[@]}")
srcsargs=$( (( ${#BACKUP_SRCS[@]} == 0 ))  || printf -- "-s %s " "${BACKUP_SRCS[@]}")
exclargs=$( (( ${#BACKUP_EXCL[@]} == 0 ))  || printf -- "-e %s " "${BACKUP_EXCL[@]}")
/bin/bash -c "sudo ${SCRIPT_DIR}/borg-append.sh $srcsargs $destargs $exclargs -p $BORG_PASS_FILE -- ${BORG_FLAGS}"

ping_success || exit 1

echo "✅ Backup complete."
