# Homeserver Cron Scripts

A collection of bash scripts for automating homeserver operations including backups, container updates, health monitoring, and system maintenance.

## Setup

### 1. Configuration

Copy `CONFIG.template.sh` to `CONFIG.sh` and fill in your environment:

```bash
cp CONFIG.template.sh CONFIG.sh
```

Key variables:
- **Backup**: `BACKUP_LOC`, `BACKUP_SSH` (backup destinations)
- **Docker**: `DOCKER_BINDS_DIR`, `DOCKER_COMPOSE_DIR`, `DOCKER_VOL_LOC`
- **Storage**: `VG`, `LV` (LVM volume group/logical volume for snapshotted backups)
- **Monitoring**: `HCHK_*` (Healthchecks.io URLs for each task)
- **Services**: `WEB_SERVICES`, `TS_DOMAIN` (Tailscale domain, web service list)

### 2. Borg Setup

Initialize Borg repositories for each backup location:

```bash
borg init --encryption=repokey /path/to/repo
```

Store passphrases in `.borg-pass-server` and `.borg-pass-containers` (chmod 600).

### 3. Cron Scheduling

Add to crontab:

```bash
# Server backup - daily at 3 AM
0 3 * * * /bin/bash -c '/path/to/server-backup.sh >> /path/to/logs/server-backup.log 2>&1'

# Container backups - weekly on Monday at 3 AM
0 3 * * 1 /bin/bash -c '/path/to/container-backups.sh >> /path/to/logs/container-backups.log 2>&1'

# Container updates - weekly on Monday at 4:30 AM
30 4 * * 1 /bin/bash -c '/path/to/auto-container-update.sh >> /path/to/logs/auto-container-update.log 2>&1'

# Health checks - as needed
*/30 * * * * /bin/bash -c '/path/to/server-health-ping.sh >> /path/to/logs/health.log 2>&1'
```

## Scripts

### Backup & Restore
- **server-backup.sh** — Back up server data via Borg (excludes Docker)
- **container-backups.sh** — Back up Docker Compose projects (binds, volumes, databases)
- **borg-action.sh** — Initialize and manage Borg repositories
- **borg-append.sh** — Append Docker data to existing Borg backups

### Container Management
- **auto-container-update.sh** — Pull and restart all Docker Compose projects
- **container-handler.sh** — Shared container control functions

### Monitoring & Health Checks
- **server-health-ping.sh** — Ping Healthchecks.io for server status
- **webservice-health-ping.sh** — Monitor web service availability
- **ping.sh** — Shared health check utilities

### Service-Specific
- **pi-clone.sh** — Clone Raspberry Pi SD cards
- **docker-service-backup.sh** — Backup individual services
- **trigger-backup-scripts/** — API-based backups for specific services:
  - beszel-trigger-backup.sh
  - mealie-trigger-backup.sh
  - paperless-trigger-backup.sh
  - immich-trigger-backup.sh
  - healthchecks-trigger-backup.sh

## Features

- **Incremental backups** with Borg deduplication
- **LVM snapshots** for consistent backups of running systems
- **Database exports** for Docker services (Mealie, Paperless, etc.)
- **Health monitoring** via Healthchecks.io integration
- **Error traps** with automatic failure reporting
- **Flexible exclusions** for logs and temporary files

## Dependencies

- Bash 4.0+
- Borg Backup
- Docker & Docker Compose
- `curl` (for healthchecks)
- `sudo` (for LVM snapshots and Borg operations)

## Notes

- All backups exclude `/var/lib/docker` and `/var/lib/containers`
- Docker volumes are backed up via Borg extracts
- For restore, extract backups from `/` to preserve ownership
- Logs directory is configured in `CONFIG.sh` and excluded from git
- Healthchecks.io URLs should be kept secret in `CONFIG.sh`
