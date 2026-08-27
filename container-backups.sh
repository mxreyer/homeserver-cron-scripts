#!/bin/bash
# ==============================================================================
# Script Name: container-backups.sh
# Description: Create borg backups for my docker compose projects. Should be
#               scheduled with cron, e.g.
#               0 3 * * 1 /bin/bash -c '<scriptdir>/container-backups.sh'
# Preparation:
#     - Initialize borg repos (borg init --encryption=repokey /path/to/repo)
#       (Can be carried out with borg-action.sh)
#     - Store Borg passphrase in .borg-pass-XXX (chmod 600).
#     - Set up the scripts in trigger-backup-scripts (API keys etc)
#
# Notes:
#     - For some services, simply all bind mounts and volumes are archived
#       (after stopping containers). In all cases, we should be able to quickly
#       restore from these backups. For some other services (where available),
#       databases are dumped for safety, too, or internal backup scripts are
#       called to create wholly docker-agnostic backups as fallback (e.g.
#       paperless, mealie). This is set up in the scripts under
#       `trigger-backup-scripts`
#     - The tailscale and caddy sidecar container volumes are included, but
#       they should actually not be required. We may decide to exclude them
#       when executing borg extract (see below). If we exclude them, we may
#       need to `docker volume rm` them so that docker can re-generate them
#       cleanly.
#     - Nextcloud is backed up via its own borg tool. The mastercontainer is
#       not backed up at all.
#     - As long as no containers are specified with -c, the following commands
#       stop all containers before appending binds and volumes to borg
#     - Because ${DOCKER_BINDS_DIR} is not explicitly part ot the backups,
#       borg does not store ownership information about this dir. When
#       extracting the backups using `sudo borg extract`, borg creates this dir
#       with root as owner if not already present. Thus, must either fix ownership
#       after extraction using chmod (non-recursive) or make sure that the
#       folder already exists with proper ownership.
#
# Restore:
#     - call borg extract from /. This puts the docker-binds and
#       /var/lib/docker/volume directories are put into the proper locations.
#       This is automated in docker-action.sh (the script allows to exclude
#       tailscale and caddy sidecar volumes).
#     - docker-action.sh may be used to mount the repos for inspection, too.
#     - Regarding the restoration of docker-agnostic backups and proper database dumps,
#       cf to the documentation of the corresponding compose projects.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/CONFIG.sh"

BACKUP_SCRIPT="${SCRIPT_DIR}/docker-service-backup.sh"

tmp_docker_file=$(mktemp)
source "${SCRIPT_DIR}/ping.sh"

# === Traps, error handling === #
on_exit() {
  rm "$tmp_docker_file"
}
trap on_exit EXIT

# === Script logic === #

# paperless
# On top of backing up bind mounts and volumes, create full docker-agnostic
# backup using "document exporter", see paperless-trigger-backup.sh
"$BACKUP_SCRIPT" \
  -p ${SCRIPT_DIR}/.borg-pass-paperless \
  -u "$HCHK_PAPERLESS" \
  -i "${SCRIPT_DIR}/trigger-backup-scripts/paperless-trigger-backup.sh" \
  -y ${DOCKER_COMPOSE_DIR}/paperless/compose.yaml \
  -s $VG/$LV:${DOCKER_BINDS_DIR}/paperless/ \
  -s $VG/$LV:${DOCKER_VOL_LOC}/paperless_caddy_certs \
  -s $VG/$LV:${DOCKER_VOL_LOC}/paperless_caddy_config \
  -s $VG/$LV:${DOCKER_VOL_LOC}/paperless_caddy_data \
  -s $VG/$LV:${DOCKER_VOL_LOC}/paperless_data \
  -s $VG/$LV:${DOCKER_VOL_LOC}/paperless_media \
  -s $VG/$LV:${DOCKER_VOL_LOC}/paperless_pgdata \
  -s $VG/$LV:${DOCKER_VOL_LOC}/paperless_redisdata \
  -s $VG/$LV:${DOCKER_VOL_LOC}/paperless_tailscale_sock \
  -d "${BACKUP_LOC}/paperless/borg" \
  -d "${BACKUP_SSH}/paperless/borg" \
  2>&1 \
  | tee -a ${LOGS_DIR}/backup-paperless.log
#-d "${BACKUP_SSH}/paperless/borg" \

# immich
# On top of backing up bind mounts and volumes, the postgres database is
# explicitly dumped for safety, see immich-trigger-backup.sh
"$BACKUP_SCRIPT" \
  -p ${SCRIPT_DIR}/.borg-pass-immich \
  -u "$HCHK_IMMICH" \
  -i "${SCRIPT_DIR}/trigger-backup-scripts/immich-trigger-backup.sh" \
  -y ${DOCKER_COMPOSE_DIR}/immich/compose.yaml \
  -C immich-server -C immich-machine-learning -C redis \
  -s $VG/$LV:${DOCKER_BINDS_DIR}/immich \
  -s $VG/$LV:${DOCKER_VOL_LOC}/immich_model-cache \
  -e ${DOCKER_BINDS_DIR}/immich/library/thumbs/ \
  -e ${DOCKER_BINDS_DIR}/immich/library/encoded-video/ \
  -d "${BACKUP_LOC}/immich/borg" \
  -d "${BACKUP_SSH}/immich/borg" \
  2>&1 \
  | tee -a ${LOGS_DIR}/backup-immich.log

# beszel
# On top of backing up bind mounts and volumes, create full docker-agnostic
# backup using beszel API, see beszel-trigger-backup.sh
"$BACKUP_SCRIPT" \
  -p ${SCRIPT_DIR}/.borg-pass-beszel \
  -u "$HCHK_BESZEL" \
  -i "${SCRIPT_DIR}/trigger-backup-scripts/beszel-trigger-backup.sh" \
  -y ${DOCKER_COMPOSE_DIR}/beszel/compose.yaml \
  -s $VG/$LV:${DOCKER_BINDS_DIR}/beszel \
  -d "${BACKUP_LOC}/beszel/borg" \
  -d "${BACKUP_SSH}/beszel/borg" \
  2>&1 \
  | tee -a ${LOGS_DIR}/backup-beszel.log

## healthchecks
## On top of backing up bind mounts and volumes, create full docker-agnostic
## backup using database dump, see healthchecks-trigger-backup.sh
#"$BACKUP_SCRIPT" \
#  -p ${SCRIPT_DIR}/.borg-pass-healthchecks \
#  -u "$HCHK_HEALTHCHECKS" \
#  -i "${SCRIPT_DIR}/trigger-backup-scripts/healthchecks-trigger-backup.sh" \
#  -y ${DOCKER_COMPOSE_DIR}/healthchecks/compose.yaml \
#  -C web \
#  -s $VG/$LV:${DOCKER_BINDS_DIR}/healthchecks \
#  -s $VG/$LV:${DOCKER_VOL_LOC}/healthchecks_caddy_certs \
#  -s $VG/$LV:${DOCKER_VOL_LOC}/healthchecks_caddy_config \
#  -s $VG/$LV:${DOCKER_VOL_LOC}/healthchecks_caddy_data \
#  -s $VG/$LV:${DOCKER_VOL_LOC}/healthchecks_db_data \
#  -s $VG/$LV:${DOCKER_VOL_LOC}/healthchecks_tailscale_sock \
#  -d "${BACKUP_LOC}/healthchecks/borg" \
#  -d "${BACKUP_SSH}/healthchecks/borg" \
#  2>&1 \
#  | tee -a ${LOGS_DIR}/backup-healthchecks.log

# mealie
# On top of backing up bind mounts and volumes, create full docker-agnostic
# backup using mealie API, see mealie-trigger-backup.sh
"$BACKUP_SCRIPT" \
  -p ${SCRIPT_DIR}/.borg-pass-mealie \
  -u "$HCHK_MEALIE" \
  -i "${SCRIPT_DIR}/trigger-backup-scripts/mealie-trigger-backup.sh" \
  -y ${DOCKER_COMPOSE_DIR}/mealie/compose.yaml \
  -s $VG/$LV:${DOCKER_BINDS_DIR}/mealie \
  -s $VG/$LV:${DOCKER_VOL_LOC}/mealie_data \
  -d "${BACKUP_LOC}/mealie/borg" \
  -d "${BACKUP_SSH}/mealie/borg" \
  2>&1 \
  | tee -a ${LOGS_DIR}/backup-mealie.log

# ollama
"$BACKUP_SCRIPT" \
  -p ${SCRIPT_DIR}/.borg-pass-ollama \
  -u "$HCHK_OLLAMA" \
  -y ${DOCKER_COMPOSE_DIR}/ollama/compose.yaml \
  -s $VG/$LV:${DOCKER_BINDS_DIR}/ollama \
  -s $VG/$LV:${DOCKER_VOL_LOC}/ollama_ollama_data/ \
  -s $VG/$LV:${DOCKER_VOL_LOC}/ollama_ollama_webui_data/ \
  -d "${BACKUP_LOC}/ollama/borg" \
  -d "${BACKUP_SSH}/ollama/borg" \
  2>&1 \
  | tee -a ${LOGS_DIR}/backup-ollama.log

# searxng
"$BACKUP_SCRIPT" \
  -p ${SCRIPT_DIR}/.borg-pass-searxng \
  -u "$HCHK_SEARXNG" \
  -y ${DOCKER_COMPOSE_DIR}/searxng/compose.yaml \
  -s $VG/$LV:${DOCKER_BINDS_DIR}/searxng \
  -s $VG/$LV:${DOCKER_VOL_LOC}/searxng_searxng-data \
  -s $VG/$LV:${DOCKER_VOL_LOC}/searxng_valkey-data2 \
  -d "${BACKUP_LOC}/searxng/borg" \
  -d "${BACKUP_SSH}/searxng/borg" \
  2>&1 \
  | tee -a ${LOGS_DIR}/backup-searxng.log

# stirling
"$BACKUP_SCRIPT" \
  -p ${SCRIPT_DIR}/.borg-pass-stirling \
  -u "$HCHK_STIRLING" \
  -y ${DOCKER_COMPOSE_DIR}/stirling/compose.yaml \
  -s $VG/$LV:${DOCKER_BINDS_DIR}/stirling \
  -s $VG/$LV:${DOCKER_VOL_LOC}/stirling_caddy_certs \
  -s $VG/$LV:${DOCKER_VOL_LOC}/stirling_caddy_config \
  -s $VG/$LV:${DOCKER_VOL_LOC}/stirling_caddy_data \
  -s $VG/$LV:${DOCKER_VOL_LOC}/stirling_tailscale_sock \
  -d "${BACKUP_LOC}/stirling/borg" \
  -d "${BACKUP_SSH}/stirling/borg" \
  2>&1 \
  | tee -a ${LOGS_DIR}/backup-stirling.log

# firefly
"$BACKUP_SCRIPT" \
  -p ${SCRIPT_DIR}/.borg-pass-firefly \
  -u "$HCHK_FIREFLY" \
  -y ${DOCKER_COMPOSE_DIR}/firefly/compose.yaml \
  -s $VG/$LV:${DOCKER_VOL_LOC}/firefly_firefly_iii_upload \
  -s $VG/$LV:${DOCKER_VOL_LOC}/firefly_firefly_iii_db \
  -d "${BACKUP_LOC}/firefly/borg" \
  -d "${BACKUP_SSH}/firefly/borg" \
  2>&1 \
  | tee -a ${LOGS_DIR}/backup-firefly.log

# actual
"$BACKUP_SCRIPT" \
  -p ${SCRIPT_DIR}/.borg-pass-actual \
  -u "$HCHK_ACTUAL" \
  -y ${DOCKER_COMPOSE_DIR}/actual/compose.yaml \
  -s $VG/$LV:${DOCKER_BINDS_DIR}/actual/data/ \
  -d "${BACKUP_LOC}/actual/borg" \
  -d "${BACKUP_SSH}/actual/borg" \
  2>&1 \
  | tee -a ${LOGS_DIR}/backup-actual.log

# template
#"$BACKUP_SCRIPT" \
#  -p ${SCRIPT_DIR}/.borg-pass- \
#  -u "https://hc-ping.com/XXX" \
#  -i "${SCRIPT_DIR}/trigger-backup-scripts/XXX-trigger-backup.sh" \
#  -y ${DOCKER_COMPOSE_DIR}/XXX/compose.yaml \
#  -c container_post\
#  -C container_pre\
#  -s $VG/$LV:${DOCKER_BINDS_DIR}/paperless/consume/ \
#  -s $VG/$LV:${DOCKER_VOL_LOC}/XXX \ 
#  -d "${BACKUP_LOC}/paperless/borg" \
#  -d "${BACKUP_SSH}/paperless/borg" \
#  -f "--verbose" \
#  2>&1 \
#  | tee -a ${LOGS_DIR}/backup-firefly.log
