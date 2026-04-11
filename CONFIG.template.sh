# General
DOCKER_BINDS_DIR=""
DOCKER_COMPOSE_DIR=""
DOCKER_VOL_LOC=""
BACKUP_LOC=""
BACKUP_SSH=""
TS_DOMAIN=""
WEB_SERVICES=""
ADD_SERVER_BACKUP_SOURCES=""
ADD_SERVER_BACKUP_EXCLSNS="" # e.g. log files that often change during backup,
                             # causing BORG error messages (when snapshotted
                             # backup not possible)
VG=""
LV=""
LOGS_DIR=""

# Healthchecks
HCHK_SERVER_BACKUP=""
HCHK_SERVER_PING=""
HCHK_WEBSERVICE_PING=""
HCHK_PI4_CLONE=""
HCHK_CONTAINER_UPDATE=""
HCHK_PAPERLESS=""
HCHK_IMMICH=""
HCHK_BESZEL=""
HCHK_HEALTHCHECKS=""
HCHK_MEALIE=""
HCHK_OLLAMA=""
HCHK_SEARXNG=""
HCHK_STIRLING=""

# API Keys
APIKY_BESZEL=""
APIKY_MEALIE=""
