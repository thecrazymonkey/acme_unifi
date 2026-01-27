#!/bin/sh
# ACME UniFi Certificate Renewal Script
# Automated SSL certificate renewal for UniFi UCG Max using acme.sh and Route53 DNS
# POSIX shell compatible for BusyBox environments

set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/acme-unifi.env"

# Default paths
ACME_HOME="${SCRIPT_DIR}/acme.sh"
CERTS_DIR="${SCRIPT_DIR}/certs"
BACKUP_DIR="${SCRIPT_DIR}/backup"
LOGS_DIR="${SCRIPT_DIR}/logs"
SECRETS_DIR="${SCRIPT_DIR}/.secrets"
AWS_CREDENTIALS="${SECRETS_DIR}/aws-credentials"

# UniFi paths
UNIFI_CERT_DIR="/data/unifi-core/config"

# Logging
LOG_FILE="${LOGS_DIR}/acme-unifi.log"
DATE_FORMAT="%Y-%m-%d %H:%M:%S"

# Colors for terminal output (disabled in non-interactive mode)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

log() {
    level="$1"
    shift
    timestamp=$(date +"${DATE_FORMAT}")
    message="[${timestamp}] [${level}] $*"
    echo "${message}" >> "${LOG_FILE}"
    case "${level}" in
        ERROR) printf "%b%s%b\n" "${RED}" "${message}" "${NC}" ;;
        WARN)  printf "%b%s%b\n" "${YELLOW}" "${message}" "${NC}" ;;
        OK)    printf "%b%s%b\n" "${GREEN}" "${message}" "${NC}" ;;
        *)     echo "${message}" ;;
    esac
}

log_info()  { log "INFO" "$@"; }
log_error() { log "ERROR" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_ok()    { log "OK" "$@"; }

die() {
    log_error "$@"
    send_notification "FAILURE" "$*"
    exit 1
}

# Send notification via webhook
send_notification() {
    status="$1"
    message="$2"

    # Skip if webhook not configured or config not yet loaded
    [ -z "${WEBHOOK_URL}" ] && return 0

    log_info "Sending ${status} notification to webhook"

    timestamp=$(date +"${DATE_FORMAT}")
    domain="${CERT_DOMAIN:-unknown}"

    # Escape special characters for JSON (quotes and backslashes)
    escaped_message=$(printf '%s' "${message}" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g')

    payload=$(printf '{"status":"%s","domain":"%s","message":"%s","timestamp":"%s"}' \
        "${status}" "${domain}" "${escaped_message}" "${timestamp}")

    # Use curl if available (with timeout)
    if command -v curl >/dev/null 2>&1; then
        curl -s -X POST -H "Content-Type: application/json" \
            --max-time 10 -d "${payload}" "${WEBHOOK_URL}" >> "${LOG_FILE}" 2>&1 || log_warn "Webhook failed"
    elif command -v wget >/dev/null 2>&1; then
        wget --quiet --timeout=10 --post-data="${payload}" \
            --header="Content-Type: application/json" "${WEBHOOK_URL}" -O - >> "${LOG_FILE}" 2>&1 || log_warn "Webhook failed"
    fi
}

# Load configuration
load_config() {
    if [ ! -f "${CONFIG_FILE}" ]; then
        die "Configuration file not found: ${CONFIG_FILE}"
    fi
    # shellcheck source=/dev/null
    . "${CONFIG_FILE}"

    # Validate required settings
    [ -z "${CERT_DOMAIN}" ] && die "CERT_DOMAIN not set in config"
    [ -z "${ACME_EMAIL}" ] && die "ACME_EMAIL not set in config"

    # Set defaults
    RENEWAL_DAYS="${RENEWAL_DAYS:-30}"
    USE_STAGING="${USE_STAGING:-false}"
    LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
    CERT_TYPE="${CERT_TYPE:-ecc}" # Default to ECC
    RESTART_UNIFI_CORE="${RESTART_UNIFI_CORE:-false}"
    WEBHOOK_URL="${WEBHOOK_URL:-}"

    # Auto-discover UUID if not set
    if [ -z "${CERT_UUID}" ] || [ "${CERT_UUID}" = "auto" ]; then
        discover_uuid
    fi
}

# Auto-discover certificate UUID from UniFi config
discover_uuid() {
    log_info "Attempting to auto-discover certificate UUID..."

    # Look for the .crt file that is most recently modified and has a UUID-like name
    # UUID pattern: 8-4-4-4-12 hex characters
    found_path=$(ls -t "${UNIFI_CERT_DIR}"/*.crt 2>/dev/null | grep -E "[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}" | head -n1)

    if [ -n "${found_path}" ]; then
        CERT_UUID=$(basename "${found_path}" .crt)
        log_info "Auto-discovered active certificate UUID: ${CERT_UUID}"
    else
        log_error "No UUID-named certificate found in ${UNIFI_CERT_DIR}"
        log_error ""
        log_error "Before using this automation, you must import a certificate manually:"
        log_error "  1. Go to UniFi Network Settings > System > Advanced"
        log_error "  2. Upload a custom certificate (can be self-signed initially)"
        log_error "  3. This creates the UUID-named certificate files the automation needs"
        log_error "  4. Run this script again after importing"
        log_error ""
        log_error "Alternatively, set CERT_UUID manually in acme-unifi.env"
        exit 1
    fi
}

# Load AWS credentials
load_aws_credentials() {
    if [ ! -f "${AWS_CREDENTIALS}" ]; then
        die "AWS credentials not found: ${AWS_CREDENTIALS}"
    fi

    # Check permissions
    perms=$(stat -c %a "${AWS_CREDENTIALS}" 2>/dev/null || stat -f %Lp "${AWS_CREDENTIALS}" 2>/dev/null)
    if [ "${perms}" != "600" ]; then
        log_warn "AWS credentials file has insecure permissions (${perms}), should be 600"
    fi

    # shellcheck source=/dev/null
    . "${AWS_CREDENTIALS}"

    [ -z "${AWS_ACCESS_KEY_ID}" ] && die "AWS_ACCESS_KEY_ID not set"
    [ -z "${AWS_SECRET_ACCESS_KEY}" ] && die "AWS_SECRET_ACCESS_KEY not set"

    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    log_info "AWS credentials loaded"
}

# Clear AWS credentials from environment
clear_aws_credentials() {
    unset AWS_ACCESS_KEY_ID
    unset AWS_SECRET_ACCESS_KEY
    log_info "AWS credentials cleared from environment"
}

# Check certificate expiry
# Returns 0 if renewal needed, 1 if not
check_cert_expiry() {
    cert_file="${UNIFI_CERT_DIR}/${CERT_UUID}.crt"

    if [ ! -f "${cert_file}" ]; then
        log_info "No existing certificate found, renewal needed"
        return 0
    fi

    # Get expiry date
    expiry_date=$(openssl x509 -in "${cert_file}" -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -z "${expiry_date}" ]; then
        log_warn "Could not read certificate expiry, renewal needed"
        return 0
    fi

    # Convert to epoch
    expiry_epoch=$(date -d "${expiry_date}" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "${expiry_date}" +%s 2>/dev/null)
    current_epoch=$(date +%s)

    # Calculate days until expiry
    days_left=$(( (expiry_epoch - current_epoch) / 86400 ))

    log_info "Certificate expires: ${expiry_date} (${days_left} days remaining)"

    if [ "${days_left}" -le "${RENEWAL_DAYS}" ]; then
        log_info "Certificate expires in ${days_left} days, renewal needed (threshold: ${RENEWAL_DAYS})"
        return 0
    else
        log_info "Certificate valid for ${days_left} days, no renewal needed"
        return 1
    fi
}

# Backup existing certificates
backup_certs() {
    cert_file="${UNIFI_CERT_DIR}/${CERT_UUID}.crt"
    key_file="${UNIFI_CERT_DIR}/${CERT_UUID}.key"

    if [ ! -f "${cert_file}" ]; then
        log_info "No existing certificate to backup"
        return 0
    fi

    backup_timestamp=$(date +%Y%m%d-%H%M%S)
    backup_subdir="${BACKUP_DIR}/${backup_timestamp}"
    mkdir -p "${backup_subdir}"

    cp "${cert_file}" "${backup_subdir}/" 2>/dev/null && log_info "Backed up certificate"
    cp "${key_file}" "${backup_subdir}/" 2>/dev/null && log_info "Backed up private key"

    log_info "Backup created: ${backup_subdir}"
}

# Run acme.sh to issue/renew certificate
run_acme() {
    force="$1"
    log_info "Starting certificate issuance for ${CERT_DOMAIN}"

    acme_cmd="${ACME_HOME}/acme.sh"

    if [ ! -x "${acme_cmd}" ]; then
        die "acme.sh not found or not executable: ${acme_cmd}"
    fi

    # Build acme.sh command
    acme_args="--issue --dns dns_aws -d ${CERT_DOMAIN}"

    # Pass --force to acme.sh to bypass its internal validity check
    # This is needed when switching from staging to production or forcing renewal
    if [ "${force}" = "force" ]; then
        acme_args="${acme_args} --force"
        log_info "Forcing certificate re-issuance (bypassing acme.sh cache)"
    fi
    acme_args="${acme_args} --home ${ACME_HOME}"
    acme_args="${acme_args} --cert-home ${CERTS_DIR}"
    acme_args="${acme_args} --accountemail ${ACME_EMAIL}"

    if [ "${CERT_TYPE}" = "ecc" ]; then
        acme_args="${acme_args} --keylength ec-256"
        log_info "Using ECC (Elliptic Curve) certificate"
    else
        acme_args="${acme_args} --keylength 4096"
        log_info "Using RSA 4096 certificate"
    fi

    if [ "${USE_STAGING}" = "true" ]; then
        acme_args="${acme_args} --staging"
        log_warn "Using Let's Encrypt STAGING server (certificates will not be trusted)"
    fi

    log_info "Running: acme.sh ${acme_args}"

    # Run acme.sh
    # Disable globbing to prevent wildcard domains (*.example.com) from expanding
    # shellcheck disable=SC2086
    set -f
    if "${acme_cmd}" ${acme_args} >> "${LOG_FILE}" 2>&1; then
        set +f
        log_ok "Certificate issued successfully"
        return 0
    else
        set +f
        log_error "Certificate issuance failed"
        return 1
    fi
}

# Deploy certificate to UniFi
deploy_cert() {
    src_cert="${CERTS_DIR}/${CERT_DOMAIN}_ecc/${CERT_DOMAIN}.cer"
    src_key="${CERTS_DIR}/${CERT_DOMAIN}_ecc/${CERT_DOMAIN}.key"
    src_fullchain="${CERTS_DIR}/${CERT_DOMAIN}_ecc/fullchain.cer"

    # Try RSA paths if ECC not found
    if [ ! -f "${src_cert}" ]; then
        src_cert="${CERTS_DIR}/${CERT_DOMAIN}/${CERT_DOMAIN}.cer"
        src_key="${CERTS_DIR}/${CERT_DOMAIN}/${CERT_DOMAIN}.key"
        src_fullchain="${CERTS_DIR}/${CERT_DOMAIN}/fullchain.cer"
    fi

    # Use fullchain if available
    if [ -f "${src_fullchain}" ]; then
        src_cert="${src_fullchain}"
    fi

    if [ ! -f "${src_cert}" ]; then
        die "Certificate file not found: ${src_cert}"
    fi
    if [ ! -f "${src_key}" ]; then
        die "Private key file not found: ${src_key}"
    fi

    dest_cert="${UNIFI_CERT_DIR}/${CERT_UUID}.crt"
    dest_key="${UNIFI_CERT_DIR}/${CERT_UUID}.key"

    log_info "Deploying certificate to ${dest_cert}"

    # Backup before deployment
    backup_certs

    # Copy files
    cp "${src_cert}" "${dest_cert}" || die "Failed to copy certificate"
    cp "${src_key}" "${dest_key}" || die "Failed to copy private key"

    # Set permissions
    chmod 644 "${dest_cert}"
    chmod 600 "${dest_key}"

    log_ok "Certificate deployed successfully"
}

# Restart services
restart_services() {
    log_info "Restarting services"

    # Restart nginx
    log_info "Restarting nginx..."
    if systemctl restart nginx >> "${LOG_FILE}" 2>&1; then
        sleep 2
        if systemctl is-active --quiet nginx; then
            log_ok "nginx restarted successfully"
        else
            log_error "nginx failed to start after restart"
            return 1
        fi
    else
        log_error "Failed to restart nginx"
        return 1
    fi

    # Optionally restart unifi-core
    if [ "${RESTART_UNIFI_CORE}" = "true" ]; then
        log_info "Restarting unifi-core..."
        if systemctl restart unifi-core >> "${LOG_FILE}" 2>&1; then
            sleep 3
            if systemctl is-active --quiet unifi-core; then
                log_ok "unifi-core restarted successfully"
            else
                log_error "unifi-core failed to start after restart"
                return 1
            fi
        else
            log_error "Failed to restart unifi-core"
            return 1
        fi
    fi

    return 0
}

# Show certificate status
show_status() {
    cert_file="${UNIFI_CERT_DIR}/${CERT_UUID}.crt"

    echo "=== ACME UniFi Certificate Status ==="
    echo ""
    echo "Configuration:"
    echo "  Domain: ${CERT_DOMAIN}"
    echo "  UUID: ${CERT_UUID}"
    echo "  Type: ${CERT_TYPE}"
    echo "  Renewal threshold: ${RENEWAL_DAYS} days"
    echo "  Staging mode: ${USE_STAGING}"
    echo "  Restart unifi-core: ${RESTART_UNIFI_CORE}"
    echo ""

    if [ -f "${cert_file}" ]; then
        echo "Certificate:"
        openssl x509 -in "${cert_file}" -noout -subject -issuer -dates 2>/dev/null | sed 's/^/  /'
        echo ""

        # Check expiry
        expiry_date=$(openssl x509 -in "${cert_file}" -noout -enddate | cut -d= -f2)
        expiry_epoch=$(date -d "${expiry_date}" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "${expiry_date}" +%s 2>/dev/null)
        current_epoch=$(date +%s)
        days_left=$(( (expiry_epoch - current_epoch) / 86400 ))

        if [ "${days_left}" -le 0 ]; then
            printf "  Status: %bEXPIRED%b\n" "${RED}" "${NC}"
        elif [ "${days_left}" -le "${RENEWAL_DAYS}" ]; then
            printf "  Status: %bRENEWAL NEEDED%b (%d days left)\n" "${YELLOW}" "${NC}" "${days_left}"
        else
            printf "  Status: %bVALID%b (%d days left)\n" "${GREEN}" "${NC}" "${days_left}"
        fi
    else
        echo "Certificate: NOT FOUND"
        echo "  Expected: ${cert_file}"
    fi

    echo ""
    echo "nginx status:"
    systemctl is-active nginx 2>/dev/null && echo "  Active: yes" || echo "  Active: no"
    echo ""

    echo "Paths:"
    echo "  Script: ${SCRIPT_DIR}"
    echo "  Certs: ${CERTS_DIR}"
    echo "  Logs: ${LOGS_DIR}"
}

# Rotate logs
rotate_logs() {
    if [ -d "${LOGS_DIR}" ]; then
        find "${LOGS_DIR}" -name "*.log" -mtime +"${LOG_RETENTION_DAYS}" -delete 2>/dev/null || true
    fi
}

# Update acme.sh from GitHub archive
update_scripts() {
    log_info "Updating acme.sh..."

    ACME_ARCHIVE="https://github.com/acmesh-official/acme.sh/archive/refs/heads/master.tar.gz"

    cd /tmp

    # Download archive
    if command -v curl >/dev/null 2>&1; then
        curl -sSL "${ACME_ARCHIVE}" -o acme.sh.tar.gz || { log_error "Failed to download acme.sh"; return 1; }
    elif command -v wget >/dev/null 2>&1; then
        wget -qO acme.sh.tar.gz "${ACME_ARCHIVE}" || { log_error "Failed to download acme.sh"; return 1; }
    else
        log_error "Neither curl nor wget available"
        return 1
    fi

    # Extract and update
    tar -xzf acme.sh.tar.gz
    cp -r acme.sh-master/* "${ACME_HOME}/"
    rm -rf acme.sh.tar.gz acme.sh-master

    cd "${SCRIPT_DIR}"

    log_ok "acme.sh updated"
}

# Main renewal workflow
do_renew() {
    force="$1"

    log_info "=== Starting certificate renewal check ==="

    # Rotate old logs
    rotate_logs

    # Check if renewal needed
    if [ "${force}" != "force" ]; then
        if ! check_cert_expiry; then
            log_info "No renewal needed, exiting"
            return 0
        fi
    else
        log_info "Force renewal requested"
    fi

    # Load AWS credentials
    load_aws_credentials

    # Issue/renew certificate
    if run_acme "${force}"; then
        # Deploy certificate
        deploy_cert

        # Restart services
        if restart_services; then
            send_notification "SUCCESS" "Certificate renewed and services restarted"
            log_ok "=== Certificate renewal completed successfully ==="
        else
            send_notification "WARN" "Certificate renewed but some services failed to restart"
            log_warn "=== Certificate renewal completed with warnings ==="
        fi
    else
        log_error "=== Certificate renewal failed ==="
        clear_aws_credentials
        return 1
    fi

    # Clear credentials
    clear_aws_credentials

    return 0
}

# Usage
usage() {
    cat <<EOF
Usage: $(basename "$0") [command]

Commands:
    renew        Check and renew certificate if needed (default)
    force-renew  Force certificate renewal regardless of expiry
    update        Update acme.sh client
    status       Show certificate status
    help         Show this help message

Examples:
    $(basename "$0")              # Check and renew if needed
    $(basename "$0") renew        # Same as above
    $(basename "$0") force-renew  # Force renewal
    $(basename "$0") status       # Show status
EOF
}

# Main
main() {
    # Ensure log directory exists
    mkdir -p "${LOGS_DIR}"

    # Load configuration
    load_config

    command="${1:-renew}"

    case "${command}" in
        renew)
            do_renew
            ;;
        force-renew|force)
            do_renew force
            ;;
        update)
            update_scripts
            ;;
        status)
            show_status
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            echo "Unknown command: ${command}"
            usage
            exit 1
            ;;
    esac
}

main "$@"
