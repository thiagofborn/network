#!/bin/bash
# =============================================================================
# GL.iNet GL-BE6500 — Router Restore
# Uploads a sysupgrade backup archive to the router and restores it.
#
# Usage:
#   ./restore-router.sh                        # picks the latest backup
#   ./restore-router.sh backup-20260414.tar.gz # use a specific backup
# =============================================================================
# What the script does
# Picks the backup — latest one automatically, or use the one you pass as argument
# Verifies the archive — checks it's not corrupt before touching the router
# Asks for confirmation — you must type YES explicitly (protects against accidents)
# Uploads via SCP to tmp on the router
# Runs sysupgrade -r — restores config files only, no firmware reflash, so it's fast (~5 sec) and safe
# Reboots the router — wait about 60 seconds, then SSH back in normally
# set -euo pipefail
# =============================================================================

# --- Configuration (must match backup-router.sh) -----------------------------
ROUTER_HOST="192.168.8.1"
ROUTER_USER="root"
SSH_KEY="$HOME/.ssh/id_ed25519"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR"
LOG_FILE="$BACKUP_DIR/restore.log"
# -----------------------------------------------------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# --- Pick the backup file ----------------------------------------------------
if [[ $# -ge 1 ]]; then
    # A specific file was passed as argument
    if [[ "$1" = /* ]]; then
        LOCAL_FILE="$1"                         # absolute path given
    else
        LOCAL_FILE="${BACKUP_DIR}/$1"           # filename only — look in backup dir
    fi
else
    # No argument — use the newest backup in the backup directory
    LOCAL_FILE=$(ls -t "${BACKUP_DIR}"/backup-*.tar.gz 2>/dev/null | head -1)
    if [[ -z "$LOCAL_FILE" ]]; then
        echo "ERROR: No backup files found in ${BACKUP_DIR}"
        exit 1
    fi
fi

if [[ ! -f "$LOCAL_FILE" ]]; then
    echo "ERROR: File not found: ${LOCAL_FILE}"
    exit 1
fi

# --- Verify the archive before sending ---------------------------------------
log "========================================="
log "Router Restore — $(date '+%Y-%m-%d %H:%M:%S')"
log "Backup file : $(basename "$LOCAL_FILE")"

if ! tar -tzf "$LOCAL_FILE" > /dev/null 2>&1; then
    log "ERROR: Archive is corrupted — aborting."
    exit 1
fi
log "Archive integrity OK."

# --- Safety confirmation -----------------------------------------------------
echo ""
echo "  Router  : ${ROUTER_USER}@${ROUTER_HOST}"
echo "  Backup  : $(basename "$LOCAL_FILE")"
echo "  Size    : $(du -sh "$LOCAL_FILE" | cut -f1)"
echo ""
echo "  The router will reboot automatically after the restore."
echo "  All current settings will be REPLACED by the backup."
echo ""
read -r -p "  Type YES to continue: " CONFIRM
if [[ "$CONFIRM" != "YES" ]]; then
    log "Restore cancelled by user."
    exit 0
fi

# --- Upload to router --------------------------------------------------------
REMOTE_FILE="/tmp/restore-$(date +%Y%m%d-%H%M%S).tar.gz"
log "Uploading backup to router at ${REMOTE_FILE} ..."
scp -i "$SSH_KEY" -o ConnectTimeout=30 \
    "$LOCAL_FILE" \
    "${ROUTER_USER}@${ROUTER_HOST}:${REMOTE_FILE}"
log "Upload complete."

# --- Restore and reboot (sysupgrade -r restores config without reflashing) ---
log "Applying backup and rebooting router..."
ssh -i "$SSH_KEY" -o ConnectTimeout=30 -o BatchMode=yes \
    "${ROUTER_USER}@${ROUTER_HOST}" \
    "sysupgrade -r ${REMOTE_FILE} && reboot" || true
# 'true' suppresses the expected SSH disconnect caused by the reboot

log "Restore command sent. Router is rebooting — wait ~60 seconds."
log "After reboot, verify connectivity with:"
log "  ssh root@${ROUTER_HOST}"
log "========================================="
