#!/bin/bash
# =============================================================================
# GL.iNet GL-BE6500 — Automatic Router Backup
# Runs on macOS. Connects via SSH, pulls a sysupgrade backup, keeps 30 days.
# =============================================================================
# pre-requisites 
# ssh -i ~/.ssh/id_ed25519 root@192.168.8.1 'opkg update && opkg install openssh-sftp-server'
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------
ROUTER_HOST="192.168.8.1"
ROUTER_USER="root"
SSH_KEY="$HOME/.ssh/id_ed25519"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR"
KEEP_DAYS=30
LOG_FILE="$BACKUP_DIR/backup.log"
# -----------------------------------------------------------------------------

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REMOTE_FILE="/tmp/backup-${TIMESTAMP}.tar.gz"
LOCAL_FILE="${BACKUP_DIR}/backup-${TIMESTAMP}.tar.gz"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "========================================="
log "Starting router backup — ${TIMESTAMP}"

# 1. Create the backup archive on the router
log "Creating sysupgrade backup on router..."
ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes \
    "${ROUTER_USER}@${ROUTER_HOST}" \
    "sysupgrade --create-backup ${REMOTE_FILE} && echo OK"

# 2. Download it to the Mac
log "Downloading backup to ${LOCAL_FILE} ..."
scp -i "$SSH_KEY" -o ConnectTimeout=10 \
    "${ROUTER_USER}@${ROUTER_HOST}:${REMOTE_FILE}" \
    "${LOCAL_FILE}"

# 3. Remove the temp file from the router (flash storage is limited)
log "Cleaning up temp file on router..."
ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes \
    "${ROUTER_USER}@${ROUTER_HOST}" \
    "rm -f ${REMOTE_FILE}"

# 4. Verify the downloaded archive is not empty / corrupted
if tar -tzf "${LOCAL_FILE}" > /dev/null 2>&1; then
    SIZE=$(du -sh "${LOCAL_FILE}" | cut -f1)
    log "Backup verified OK — size: ${SIZE}"
else
    log "ERROR: Backup archive is corrupted. Removing bad file."
    rm -f "${LOCAL_FILE}"
    exit 1
fi

# 5. Rotate old backups — delete anything older than KEEP_DAYS days
log "Rotating backups older than ${KEEP_DAYS} days..."
find "${BACKUP_DIR}" -name "backup-*.tar.gz" -mtime +${KEEP_DAYS} -print -delete \
    | while read -r deleted; do log "Deleted old backup: $(basename "$deleted")"; done

# 6. List current backups
BACKUP_COUNT=$(find "${BACKUP_DIR}" -name "backup-*.tar.gz" | wc -l | tr -d ' ')
log "Backup complete. Total backups on disk: ${BACKUP_COUNT}"
log "========================================="
