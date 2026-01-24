#!/bin/sh
# ACME UniFi Installer
# One-time setup for certificate automation on UniFi UCG Max

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ACME_HOME="${SCRIPT_DIR}/acme.sh"
CERTS_DIR="${SCRIPT_DIR}/certs"
BACKUP_DIR="${SCRIPT_DIR}/backup"
LOGS_DIR="${SCRIPT_DIR}/logs"
SECRETS_DIR="${SCRIPT_DIR}/.secrets"
CRONJOBS_DIR="/data/cronjobs"
ON_BOOT_DIR="/data/on_boot.d"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { printf "%b[INFO]%b %s\n" "${GREEN}" "${NC}" "$*"; }
warn()  { printf "%b[WARN]%b %s\n" "${YELLOW}" "${NC}" "$*"; }
error() { printf "%b[ERROR]%b %s\n" "${RED}" "${NC}" "$*"; }
die()   { error "$*"; exit 1; }

# Check if running as root
check_root() {
    if [ "$(id -u)" != "0" ]; then
        die "This script must be run as root"
    fi
}

# Create directory structure
create_directories() {
    info "Creating directory structure..."

    mkdir -p "${CERTS_DIR}"
    mkdir -p "${BACKUP_DIR}"
    mkdir -p "${LOGS_DIR}"
    mkdir -p "${SECRETS_DIR}"
    mkdir -p "${CRONJOBS_DIR}"
    mkdir -p "${ON_BOOT_DIR}"

    # Secure secrets directory
    chmod 700 "${SECRETS_DIR}"

    info "Directories created"
}

# Install acme.sh from official GitHub repository
# https://github.com/acmesh-official/acme.sh
install_acme() {
    ACME_REPO="https://github.com/acmesh-official/acme.sh.git"

    if [ -d "${ACME_HOME}" ] && [ -x "${ACME_HOME}/acme.sh" ]; then
        info "acme.sh already installed, checking for updates..."
        if command -v git >/dev/null 2>&1 && [ -d "${ACME_HOME}/.git" ]; then
            cd "${ACME_HOME}"
            git pull --quiet 2>/dev/null || warn "Could not update via git"
            cd "${SCRIPT_DIR}"
        else
            cd "${ACME_HOME}"
            ./acme.sh --upgrade --home "${ACME_HOME}" 2>/dev/null || true
            cd "${SCRIPT_DIR}"
        fi
        return 0
    fi

    info "Installing acme.sh from ${ACME_REPO}..."

    # Method 1: Clone via git (preferred)
    if command -v git >/dev/null 2>&1; then
        info "Cloning acme.sh repository..."
        git clone --depth 1 "${ACME_REPO}" "${ACME_HOME}" 2>/dev/null
        if [ -x "${ACME_HOME}/acme.sh" ]; then
            info "acme.sh cloned successfully"
            return 0
        fi
        warn "Git clone failed, trying archive download..."
        rm -rf "${ACME_HOME}"
    fi

    # Method 2: Download archive (fallback for systems without git)
    info "Downloading acme.sh archive..."
    ACME_ARCHIVE="https://github.com/acmesh-official/acme.sh/archive/refs/heads/master.tar.gz"

    mkdir -p "${ACME_HOME}"
    cd /tmp

    if command -v curl >/dev/null 2>&1; then
        curl -sSL "${ACME_ARCHIVE}" -o acme.sh.tar.gz
    elif command -v wget >/dev/null 2>&1; then
        wget -qO acme.sh.tar.gz "${ACME_ARCHIVE}"
    else
        die "Neither git, curl, nor wget available"
    fi

    # Extract to ACME_HOME
    tar -xzf acme.sh.tar.gz
    cp -r acme.sh-master/* "${ACME_HOME}/"
    rm -rf acme.sh.tar.gz acme.sh-master

    cd "${SCRIPT_DIR}"

    if [ -x "${ACME_HOME}/acme.sh" ]; then
        info "acme.sh installed successfully"
    else
        # Make executable if needed
        chmod +x "${ACME_HOME}/acme.sh" 2>/dev/null || true
        if [ -x "${ACME_HOME}/acme.sh" ]; then
            info "acme.sh installed successfully"
        else
            die "acme.sh installation failed"
        fi
    fi
}

# Setup AWS credentials
setup_credentials() {
    creds_file="${SECRETS_DIR}/aws-credentials"

    if [ -f "${creds_file}" ]; then
        info "AWS credentials file exists"
        # Ensure correct permissions
        chmod 600 "${creds_file}"
        return 0
    fi

    if [ -f "${SCRIPT_DIR}/aws-credentials.example" ]; then
        cp "${SCRIPT_DIR}/aws-credentials.example" "${creds_file}"
        chmod 600 "${creds_file}"
        warn "Created ${creds_file} from template"
        warn "IMPORTANT: Edit this file with your AWS credentials before running"
    else
        cat > "${creds_file}" <<'EOF'
# AWS Credentials for Route53 DNS Challenge
# IMPORTANT: Keep this file secure (chmod 600)

export AWS_ACCESS_KEY_ID=""
export AWS_SECRET_ACCESS_KEY=""

# Optional: If using a specific region
# export AWS_DEFAULT_REGION="us-east-1"
EOF
        chmod 600 "${creds_file}"
        warn "Created empty credentials file: ${creds_file}"
        warn "IMPORTANT: Edit this file with your AWS credentials"
    fi
}

# Setup cron job
setup_cron() {
    cron_file="${CRONJOBS_DIR}/acme-unifi"

    info "Setting up cron job..."

    # Create cron entry (runs daily at 3:00 AM)
    cat > "${cron_file}" <<EOF
# ACME UniFi Certificate Renewal
# Runs daily at 3:00 AM
0 3 * * * root ${SCRIPT_DIR}/acme-unifi.sh renew >> ${LOGS_DIR}/cron.log 2>&1
EOF

    chmod 644 "${cron_file}"

    # Install cron file to /etc/cron.d/
    if [ -d "/etc/cron.d" ]; then
        cp "${cron_file}" "/etc/cron.d/acme-unifi"
        info "Cron job installed to /etc/cron.d/"
    else
        warn "Could not install cron job, /etc/cron.d not found"
    fi
}

# Setup boot persistence
setup_boot_persistence() {
    boot_script="${ON_BOOT_DIR}/10-acme-cron.sh"

    info "Setting up boot persistence..."

    # Copy boot script
    if [ -f "${SCRIPT_DIR}/on-boot-cron.sh" ]; then
        cp "${SCRIPT_DIR}/on-boot-cron.sh" "${boot_script}"
    else
        cat > "${boot_script}" <<'EOF'
#!/bin/sh
# Restore ACME cron job after firmware upgrade
# UniFi OS wipes /etc/cron.d/ on updates

CRON_SOURCE="/data/cronjobs/acme-unifi"
CRON_DEST="/etc/cron.d/acme-unifi"

if [ -f "${CRON_SOURCE}" ] && [ -d "/etc/cron.d" ]; then
    cp "${CRON_SOURCE}" "${CRON_DEST}"
    chmod 644 "${CRON_DEST}"
    logger -t acme-unifi "Restored cron job after boot"
fi
EOF
    fi

    chmod 755 "${boot_script}"
    info "Boot persistence script installed: ${boot_script}"
}

# Make main script executable
setup_permissions() {
    info "Setting up permissions..."

    chmod 755 "${SCRIPT_DIR}/acme-unifi.sh"
    chmod 644 "${SCRIPT_DIR}/acme-unifi.env"

    info "Permissions configured"
}

# Verify configuration
verify_config() {
    config_file="${SCRIPT_DIR}/acme-unifi.env"

    if [ ! -f "${config_file}" ]; then
        warn "Configuration file not found: ${config_file}"
        warn "Please create it from the template before running"
        return 1
    fi

    # shellcheck source=/dev/null
    . "${config_file}"

    if [ "${CERT_DOMAIN}" = "gateway.example.com" ]; then
        warn "CERT_DOMAIN is still set to example value"
        warn "Edit ${config_file} with your actual domain"
    fi

    if [ "${CERT_UUID}" = "7f132919-e141-43b7-8ee3-ad7c3fee4c39" ]; then
        warn "CERT_UUID may need to be updated"
        warn "Find your UUID: ls /data/unifi-core/config/*.crt"
    fi

    return 0
}

# Print summary
print_summary() {
    cat <<EOF

${GREEN}=== Installation Complete ===${NC}

Directory structure:
  ${SCRIPT_DIR}/
  ├── acme-unifi.sh      Main script
  ├── acme-unifi.env     Configuration
  ├── acme.sh/           ACME client
  ├── certs/             Certificate storage
  ├── backup/            Certificate backups
  ├── logs/              Log files
  └── .secrets/
      └── aws-credentials  AWS credentials (${YELLOW}EDIT THIS${NC})

Next steps:
  1. Edit configuration:
     ${YELLOW}vi ${SCRIPT_DIR}/acme-unifi.env${NC}

  2. Add AWS credentials:
     ${YELLOW}vi ${SECRETS_DIR}/aws-credentials${NC}

  3. Find your certificate UUID:
     ${YELLOW}ls /data/unifi-core/config/*.crt${NC}

  4. Test with staging server first:
     Set USE_STAGING="true" in acme-unifi.env
     ${YELLOW}${SCRIPT_DIR}/acme-unifi.sh force-renew${NC}

  5. After testing, switch to production:
     Set USE_STAGING="false" in acme-unifi.env
     ${YELLOW}${SCRIPT_DIR}/acme-unifi.sh force-renew${NC}

  6. Check status:
     ${YELLOW}${SCRIPT_DIR}/acme-unifi.sh status${NC}

Cron schedule: Daily at 3:00 AM
Logs: ${LOGS_DIR}/

EOF
}

# Main
main() {
    echo ""
    info "ACME UniFi Installer"
    echo ""

    check_root
    create_directories
    install_acme
    setup_credentials
    setup_permissions
    setup_cron
    setup_boot_persistence
    verify_config
    print_summary
}

main "$@"
