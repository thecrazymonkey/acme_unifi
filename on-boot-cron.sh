#!/bin/sh
# ACME UniFi Cron Persistence Script
# Restores the cron job after UniFi OS firmware upgrades
#
# UniFi OS wipes /etc/cron.d/ on firmware updates, so we store
# our cron file in /data/cronjobs/ and restore it on boot.
#
# This script should be placed in /data/on_boot.d/ which survives
# firmware updates and runs scripts on boot.

CRON_SOURCE="/data/cronjobs/acme-unifi"
CRON_DEST="/etc/cron.d/acme-unifi"

# Log function
log() {
    logger -t acme-unifi "$*"
    echo "[acme-unifi] $*"
}

# Check if source cron file exists
if [ ! -f "${CRON_SOURCE}" ]; then
    log "Cron source file not found: ${CRON_SOURCE}"
    exit 0
fi

# Check if /etc/cron.d exists
if [ ! -d "/etc/cron.d" ]; then
    log "Cron directory not found: /etc/cron.d"
    exit 0
fi

# Check if cron job already installed
if [ -f "${CRON_DEST}" ]; then
    # Compare files
    if cmp -s "${CRON_SOURCE}" "${CRON_DEST}"; then
        log "Cron job already installed and up to date"
        exit 0
    fi
fi

# Install cron job
cp "${CRON_SOURCE}" "${CRON_DEST}"
chmod 644 "${CRON_DEST}"

log "Restored ACME certificate renewal cron job"

# Restart cron service if needed
if command -v systemctl >/dev/null 2>&1; then
    systemctl restart cron 2>/dev/null || true
fi

exit 0
