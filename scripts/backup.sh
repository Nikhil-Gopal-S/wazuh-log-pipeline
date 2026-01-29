#!/bin/bash
# =============================================================================
# Wazuh API Configuration Backup Script
# =============================================================================
# Creates encrypted backups of configuration files, secrets, and certificates
#
# Usage: ./scripts/backup.sh [options]
#   -p, --password    Encryption password (or set BACKUP_PASSWORD env var)
#   -o, --output      Output directory (default: ./backups)
#   -r, --retention   Number of backups to keep (default: 7)
#   -v, --verify      Verify backup after creation
#   -h, --help        Show help message

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="${PROJECT_ROOT}/backups"
RETENTION_COUNT=7
TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
BACKUP_NAME="wazuh-api-backup_${TIMESTAMP}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Backup targets
BACKUP_TARGETS=(
    "docker-compose.yml"
    "Dockerfile"
    "Dockerfile.agent"
    ".dockerignore"
    "deploy/nginx/"
    "deploy/fail2ban/"
    "api/api.py"
    "api/requirements.txt"
    "api/start.sh"
    "bin/"
    "config/"
    "scripts/"
)

# Sensitive files (will be encrypted)
SENSITIVE_TARGETS=(
    "secrets/"
    "deploy/nginx/certs/"
)

# Functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

show_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -p, --password    Encryption password"
    echo "  -o, --output      Output directory (default: ./backups)"
    echo "  -r, --retention   Number of backups to keep (default: 7)"
    echo "  -v, --verify      Verify backup after creation"
    echo "  -h, --help        Show this help message"
}

create_backup() {
    local backup_path="${BACKUP_DIR}/${BACKUP_NAME}"
    mkdir -p "$backup_path"
    
    log_info "Creating backup: $BACKUP_NAME"
    
    # Backup regular files
    log_info "Backing up configuration files..."
    for target in "${BACKUP_TARGETS[@]}"; do
        if [ -e "${PROJECT_ROOT}/${target}" ]; then
            # Create parent directory if needed
            local target_dir=$(dirname "${backup_path}/${target}")
            mkdir -p "$target_dir"
            cp -r "${PROJECT_ROOT}/${target}" "${backup_path}/${target}"
            log_info "  ✓ $target"
        else
            log_warn "  ✗ $target (not found)"
        fi
    done
    
    # Backup and encrypt sensitive files
    log_info "Backing up and encrypting sensitive files..."
    for target in "${SENSITIVE_TARGETS[@]}"; do
        if [ -d "${PROJECT_ROOT}/${target}" ]; then
            # Check if directory has any files (excluding .gitignore)
            if find "${PROJECT_ROOT}/${target}" -type f ! -name '.gitignore' | grep -q .; then
                tar -czf - -C "$PROJECT_ROOT" "$target" | \
                    openssl enc -aes-256-cbc -salt -pbkdf2 -pass pass:"$BACKUP_PASSWORD" \
                    > "${backup_path}/${target//\//_}.tar.gz.enc"
                log_info "  ✓ $target (encrypted)"
            else
                log_warn "  ✗ $target (empty or only contains .gitignore)"
            fi
        else
            log_warn "  ✗ $target (not found)"
        fi
    done
    
    # Create manifest
    create_manifest "$backup_path"
    
    # Create final archive
    log_info "Creating backup archive..."
    cd "$BACKUP_DIR"
    tar -czf "${BACKUP_NAME}.tar.gz" "$BACKUP_NAME"
    rm -rf "$BACKUP_NAME"
    
    log_info "Backup created: ${BACKUP_DIR}/${BACKUP_NAME}.tar.gz"
}

create_manifest() {
    local backup_path="$1"
    local manifest_file="${backup_path}/MANIFEST.txt"
    
    cat > "$manifest_file" << EOF
# Wazuh API Backup Manifest
# Created: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Hostname: $(hostname)
# Backup Name: ${BACKUP_NAME}

## Backup Contents
$(find "$backup_path" -type f | sed "s|$backup_path/||" | sort)

## Encrypted Files
$(for f in "${SENSITIVE_TARGETS[@]}"; do 
    enc_file="${f//\//_}.tar.gz.enc"
    if [ -f "${backup_path}/${enc_file}" ]; then
        echo "- ${enc_file}"
    fi
done)

## Restore Instructions
1. Extract backup archive:
   tar -xzf ${BACKUP_NAME}.tar.gz

2. Decrypt sensitive files (secrets):
   openssl enc -d -aes-256-cbc -pbkdf2 -in secrets_.tar.gz.enc -pass pass:"\$PASSWORD" | tar -xzf -

3. Decrypt sensitive files (certificates):
   openssl enc -d -aes-256-cbc -pbkdf2 -in deploy_nginx_certs_.tar.gz.enc -pass pass:"\$PASSWORD" | tar -xzf -

4. Copy files to appropriate locations in the project directory

5. Restart services:
   docker-compose down
   docker-compose up -d

## Verification
To verify backup integrity:
   tar -tzf ${BACKUP_NAME}.tar.gz

## Notes
- Encrypted files use AES-256-CBC with PBKDF2 key derivation
- Keep the encryption password secure and separate from backups
- Test restore procedures periodically
EOF
    
    log_info "Manifest created"
}

apply_retention() {
    log_info "Applying retention policy (keeping last $RETENTION_COUNT backups)..."
    cd "$BACKUP_DIR"
    
    # Count existing backups
    local backup_count=$(ls -1 wazuh-api-backup_*.tar.gz 2>/dev/null | wc -l)
    
    if [ "$backup_count" -gt "$RETENTION_COUNT" ]; then
        # Delete oldest backups beyond retention count
        ls -t wazuh-api-backup_*.tar.gz 2>/dev/null | tail -n +$((RETENTION_COUNT + 1)) | while read -r old_backup; do
            log_info "  Removing old backup: $old_backup"
            rm -f "$old_backup"
        done
        log_info "Retention policy applied"
    else
        log_info "No old backups to remove (current: $backup_count, retention: $RETENTION_COUNT)"
    fi
}

verify_backup() {
    local backup_file="${BACKUP_DIR}/${BACKUP_NAME}.tar.gz"
    log_info "Verifying backup integrity..."
    
    if tar -tzf "$backup_file" > /dev/null 2>&1; then
        local file_count=$(tar -tzf "$backup_file" | wc -l)
        local file_size=$(ls -lh "$backup_file" | awk '{print $5}')
        log_info "✓ Backup archive is valid"
        log_info "  Files: $file_count"
        log_info "  Size: $file_size"
    else
        log_error "✗ Backup archive is corrupted"
        exit 1
    fi
}

# Parse arguments
VERIFY=false
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--password) BACKUP_PASSWORD="$2"; shift 2 ;;
        -o|--output) BACKUP_DIR="$2"; shift 2 ;;
        -r|--retention) RETENTION_COUNT="$2"; shift 2 ;;
        -v|--verify) VERIFY=true; shift ;;
        -h|--help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# Check for password
if [ -z "${BACKUP_PASSWORD:-}" ]; then
    read -sp "Enter backup encryption password: " BACKUP_PASSWORD
    echo
fi

# Validate password
if [ -z "$BACKUP_PASSWORD" ]; then
    log_error "Encryption password is required"
    exit 1
fi

if [ ${#BACKUP_PASSWORD} -lt 8 ]; then
    log_error "Encryption password must be at least 8 characters"
    exit 1
fi

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Run backup
log_info "Starting backup process..."
log_info "Project root: $PROJECT_ROOT"
log_info "Backup directory: $BACKUP_DIR"
echo ""

create_backup
apply_retention

if [ "$VERIFY" = true ]; then
    verify_backup
fi

echo ""
log_info "Backup completed successfully!"
log_info "Backup file: ${BACKUP_DIR}/${BACKUP_NAME}.tar.gz"