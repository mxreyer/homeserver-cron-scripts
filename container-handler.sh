#!/bin/bash
# ==============================================================================
# Script Name: container-handler.sh
# Description: Provides functions to stop and restart all docker containers
#
# Note:
#   - Consider implementing a healthcheck?
#     I.e. ping failure if docker compose up throws error.
# ==============================================================================

# Check input
if [ -z "$tmp_docker_file" ]; then
  echo "Error: Must specify tmp_docker_file."
  return 1
else
  export tmp_docker_file=$(realpath "$tmp_docker_file")
fi

# Get all unique compose projects and their working directories
docker ps \
  --format '{{.Label "com.docker.compose.project"}} {{.Label "com.docker.compose.project.working_dir"}}' \
  | sort -u > "$tmp_docker_file"

# remove empty lines stemming from containers that are not part of a compose project 
sed -i '/^\s*$/d' "$tmp_docker_file"

stop_docker() {
  echo "🐳 Stopping containers..."
  echo "🌊🌊🌊🌊🌊🌊🌊🌊🌊🌊🌊🌊🌊🌊🌊🌊🌊"
  # check input
  if [ ! -f "$tmp_docker_file" ]; then
    echo "File $tmp_docker_file noes not exist. Exit."
    return 1
  fi
  # stop nextcloud containers through daily-backup script of nextcloud-aio-mastercontainer
  echo "Stopping ☁️  Nextcloud containers..."
  responsefile=$(mktemp)
  docker exec --env DAILY_BACKUP=0 --env STOP_CONTAINERS=1 --env START_CONTAINERS=0 \
    nextcloud-aio-mastercontainer /daily-backup.sh 2>&1 | tee "$responsefile"
  if $(grep -i "error" -q "$responsefile"); then
    echo "Error stopping nextcloud containers."
    rm "$responsefile"
    return 1
  fi
  rm "$responsefile";
  # stop compose projects
  while read -r project dir; do
    echo "Stopping 🎼 compose project $project in $dir"
    (cd "$dir" && docker compose down)
    #if [[ "$1" == "--no_ts_cdy" ]]; then
    #  # exclude tailscale and caddy 
    #  (cd "$dir" && docker compose ps -q | grep -v -E "$(docker compose ps -q tailscale caddy | paste -sd'|' -)" | xargs -r docker stop)
    #else
    #  # include tailscale and caddy 
    #  (cd "$dir" && docker compose down)
    #fi
  done < "$tmp_docker_file"
}

start_docker() {
  echo "🐳 Starting containers..."
  # check input
  echo "🌊🌊🌊🌊🌊🌊🌊🌊🌊🌊🌊🌊🌊🌊🌊🌊🌊"
  if [ ! -f "$tmp_docker_file" ]; then
    echo "Error: File $tmp_docker_file noes not exist!"
    return 1
  fi
  # start compose projects
  while read -r project dir; do
    echo "Starting 🎼 compose project $project in $dir"
    (cd "$dir" && docker compose up -d)
  done < "$tmp_docker_file"
  # start nextcloud containers through daily-backup script of nextcloud-aio-mastercontainer
  echo "Starting ☁️  Nextcloud containers..."
  responsefile=$(mktemp)
  docker exec --env DAILY_BACKUP=0 --env STOP_CONTAINERS=0 --env START_CONTAINERS=1 \
    nextcloud-aio-mastercontainer /daily-backup.sh 2>&1 | tee "$responsefile"
  if $(grep -i "error" -q "$responsefile"); then
    echo "Error starting nextcloud containers."
    rm "$responsefile"
    return 1
  fi
  rm "$responsefile";
}

pull_docker() {
  echo "🐳 Pulling containers..."
  echo "🌊🌊🌊🌊🌊🌊🌊🌊🌊🌊🌊🌊🌊🌊🌊🌊🌊"
  # check input
  if [ ! -f "$tmp_docker_file" ]; then
    echo "Error: File $tmp_docker_file noes not exist."
    return 1
  fi
  # pull compose projects
  while read -r project dir; do
    echo "Pull 🎼 compose project $project in $dir"
    (cd "$dir" && docker compose pull)
  done < "$tmp_docker_file"
}
