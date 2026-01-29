#!/bin/bash
# =============================================================================
# Wazuh API Configuration Restore Script
# =============================================================================
# Restores configuration from encrypted backups
#
# Usage: ./scripts/restore.sh <backup-file> [options]
#   -p, --password    Decryption password (or set BACKUP_PASSWORD env var)
#   -d, --dry-run     Show what would be restored without making changes
#   -f, --force       Skip confirmation prompts
#   -n, --no-restart  Don't restart services after restore
#   -h, --help        Show help message

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ROLLBACK_DIR="${PROJECT_ROOT}/.restore_rollback"
LOG_FILE="${PROJECT_ROOT}/restore.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Restore targets (must match backup.sh)
RESTORE_TARGETS=(
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

SENSITIVE_TARGETS=(
    "secrets/"
    "deploy/nginx/certs/"
)

# Functions
log() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $1" | tee -a "$LOG_FILE"; }
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; log "INFO: $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; log "WARN: $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; log "ERROR: $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; log "STEP: $1"; }

show_help() {
    echo "Usage: $0 <backup-file> [options]"
    echo ""
    echo "Arguments:"
    echo "  backup-file       Path to backup archive (.tar.gz)"
    echo ""
    echo "Options:"
    echo "  -p, --password    Decryption password"
    echo "  -d, --dry-run     Show what would be restored"
    echo "  -f, --force       Skip confirmation prompts"
    echo "  -n, --no-restart  Don't restart services after restore"
    echo "  -h, --help        Show this help message"
}

create_rollback() {
    log_step "Creating rollback point..."
    rm -rf "$ROLLBACK_DIR"
    mkdir -p "$ROLLBACK_DIR"
    
    for target in "${RESTORE_TARGETS[@]}"; do
        if [ -e "${PROJECT_ROOT}/${target}" ]; then
            # Create parent directory if needed
            local target_dir=$(dirname "${ROLLBACK_DIR}/${target}")
            mkdir -p "$target_dir"
            cp -r "${PROJECT_ROOT}/${target}" "${ROLLBACK_DIR}/${target}"
        fi
    done
    
    for target in "${SENSITIVE_TARGETS[@]}"; do
        if [ -d "${PROJECT_ROOT}/${target}" ]; then
            # Create parent directory if needed
            local target_dir=$(dirname "${ROLLBACK_DIR}/${target}")
            mkdir -p "$target_dir"
            cp -r "${PROJECT_ROOT}/${target}" "${ROLLBACK_DIR}/${target}"
        fi
    done
    
    log_info "Rollback point created at $ROLLBACK_DIR"
}

rollback() {
    log_error "Restore failed! Rolling back..."
    
    if [ -d "$ROLLBACK_DIR" ]; then
        for target in "${RESTORE_TARGETS[@]}"; do
            if [ -e "${ROLLBACK_DIR}/${target}" ]; then
                # Create parent directory if needed
                local target_dir=$(dirname "${PROJECT_ROOT}/${target}")
                mkdir -p "$target_dir"
                rm -rf "${PROJECT_ROOT}/${target}"
                cp -r "${ROLLBACK_DIR}/${target}" "${PROJECT_ROOT}/${target}"
            fi
        done
        
        for target in "${SENSITIVE_TARGETS[@]}"; do
            if [ -d "${ROLLBACK_DIR}/${target}" ]; then
                # Create parent directory if needed
                local target_dir=$(dirname "${PROJECT_ROOT}/${target}")
                mkdir -p "$target_dir"
                rm -rf "${PROJECT_ROOT}/${target}"
                cp -r "${ROLLBACK_DIR}/${target}" "${PROJECT_ROOT}/${target}"
            fi
        done
        
        log_info "Rollback completed"
    else
        log_error "No rollback point available!"
    fi
    
    exit 1
}

stop_services() {
    log_step "Stopping services..."
    cd "$PROJECT_ROOT"
    if docker-compose ps -q 2>/dev/null | grep -q .; then
        docker-compose down || log_warn "Failed to stop some services"
    else
        log_info "No services running"
    fi
}

start_services() {
    log_step "Starting services..."
    cd "$PROJECT_ROOT"
    docker-compose up -d || log_error "Failed to start services"
    log_info "Services started"
}

extract_backup() {
    local backup_file="$1"
    local extract_dir="$2"
    
    log_step "Extracting backup archive..."
    mkdir -p "$extract_dir"
    tar -xzf "$backup_file" -C "$extract_dir"
    
    # Find the actual backup directory (it's nested)
    local backup_name=$(ls "$extract_dir" | head -1)
    echo "${extract_dir}/${backup_name}"
}

decrypt_sensitive() {
    local backup_dir="$1"
    
    log_step "Decrypting sensitive files..."
    
    for target in "${SENSITIVE_TARGETS[@]}"; do
        local enc_file="${backup_dir}/${target//\//_}.tar.gz.enc"
        if [ -f "$enc_file" ]; then
            log_info "Decrypting: $target"
            openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:"$BACKUP_PASSWORD" \
                -in "$enc_file" | tar -xzf - -C "$PROJECT_ROOT" || {
                log_error "Failed to decrypt $target"
                return 1
            }
        else
            log_warn "Encrypted file not found: $enc_file"
        fi
    done
}

restore_files() {
    local backup_dir="$1"
    
    log_step "Restoring configuration files..."
    
    for target in "${RESTORE_TARGETS[@]}"; do
        local source="${backup_dir}/${target}"
        local dest="${PROJECT_ROOT}/${target}"
        
        if [ -e "$source" ]; then
            # Create parent directory if needed
            mkdir -p "$(dirname "$dest")"
            
            # Remove existing and copy new
            rm -rf "$dest"
            cp -r "$source" "$dest"
            log_info "Restored: $target"
        else
            log_warn "Not in backup: $target"
        fi
    done
}

set_permissions() {
    log_step "Setting file permissions..."
    
    # Make scripts executable
    if [ -d "${PROJECT_ROOT}/scripts" ]; then
        chmod +x "${PROJECT_ROOT}/scripts/"*.sh 2>/dev/null || true
        log_info "Made scripts executable"
    fi
    
    if [ -f "${PROJECT_ROOT}/api/start.sh" ]; then
        chmod +x "${PROJECT_ROOT}/api/start.sh"
        log_info "Made api/start.sh executable"
    fi
    
    if [ -d "${PROJECT_ROOT}/bin" ]; then
        chmod +x "${PROJECT_ROOT}/bin/"*.sh 2>/dev/null || true
        log_info "Made bin scripts executable"
    fi
    
    # Secure secrets directory
    if [ -d "${PROJECT_ROOT}/secrets" ]; then
        chmod 700 "${PROJECT_ROOT}/secrets"
        chmod 600 "${PROJECT_ROOT}/secrets/"* 2>/dev/null || true
        log_info "Secured secrets directory"
    fi
    
    # Secure certificates
    if [ -d "${PROJECT_ROOT}/deploy/nginx/certs" ]; then
        chmod 600 "${PROJECT_ROOT}/deploy/nginx/certs/"*.key 2>/dev/null || true
        chmod 644 "${PROJECT_ROOT}/deploy/nginx/certs/"*.crt 2>/dev/null || true
        chmod 644 "${PROJECT_ROOT}/deploy/nginx/certs/"*.pem 2>/dev/null || true
        log_info "Secured certificate files"
    fi
}

verify_restore() {
    log_step "Verifying restore..."
    local errors=0
    local warnings=0
    
    for target in "${RESTORE_TARGETS[@]}"; do
        if [ ! -e "${PROJECT_ROOT}/${target}" ]; then
            log_warn "Missing after restore: $target"
            ((warnings++))
        fi
    done
    
    # Check critical files
    local critical_files=(
        "docker-compose.yml"
        "api/api.py"
    )
    
    for file in "${critical_files[@]}"; do
        if [ ! -f "${PROJECT_ROOT}/${file}" ]; then
            log_error "Critical file missing: $file"
            ((errors++))
        fi
    done
    
    if [ $errors -eq 0 ]; then
        if [ $warnings -eq 0 ]; then
            log_info "✓ All files restored successfully"
        else
            log_info "✓ Restore completed with $warnings warnings"
        fi
        return 0
    else
        log_error "✗ $errors critical files missing after restore"
        return 1
    fi
}

cleanup() {
    log_step "Cleaning up..."
    if [ -n "${TEMP_DIR:-}" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
    rm -rf "$ROLLBACK_DIR"
}

# Parse arguments
BACKUP_FILE=""
DRY_RUN=false
FORCE=false
NO_RESTART=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--password) BACKUP_PASSWORD="$2"; shift 2 ;;
        -d|--dry-run) DRY_RUN=true; shift ;;
        -f|--force) FORCE=true; shift ;;
        -n|--no-restart) NO_RESTART=true; shift ;;
        -h|--help) show_help; exit 0 ;;
        -*) log_error "Unknown option: $1"; show_help; exit 1 ;;
        *) BACKUP_FILE="$1"; shift ;;
    esac
done

# Validate backup file
if [ -z "$BACKUP_FILE" ]; then
    log_error "Backup file required"
    show_help
    exit 1
fi

if [ ! -f "$BACKUP_FILE" ]; then
    log_error "Backup file not found: $BACKUP_FILE"
    exit 1
fi

# Check for password
if [ -z "${BACKUP_PASSWORD:-}" ]; then
    read -sp "Enter backup decryption password: " BACKUP_PASSWORD
    echo
fi

# Validate password
if [ -z "$BACKUP_PASSWORD" ]; then
    log_error "Decryption password is required"
    exit 1
fi

# Confirmation
if [ "$FORCE" = false ] && [ "$DRY_RUN" = false ]; then
    echo -e "${YELLOW}WARNING: This will overwrite current configuration!${NC}"
    echo "Backup file: $BACKUP_FILE"
    echo ""
    echo "The following will be restored:"
    for target in "${RESTORE_TARGETS[@]}"; do
        echo "  - $target"
    done
    echo ""
    echo "Encrypted files to decrypt:"
    for target in "${SENSITIVE_TARGETS[@]}"; do
        echo "  - $target"
    done
    echo ""
    read -p "Continue? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "Restore cancelled"
        exit 0
    fi
fi

# Initialize log
echo "=== Restore started at $(date -u +"%Y-%m-%dT%H:%M:%SZ") ===" >> "$LOG_FILE"
log_info "Backup file: $BACKUP_FILE"

# Create temp directory
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

if [ "$DRY_RUN" = true ]; then
    log_info "DRY RUN - No changes will be made"
    backup_dir=$(extract_backup "$BACKUP_FILE" "$TEMP_DIR")
    log_info "Would restore from: $backup_dir"
    echo ""
    log_info "Files to restore:"
    for target in "${RESTORE_TARGETS[@]}"; do
        if [ -e "${backup_dir}/${target}" ]; then
            echo -e "  ${GREEN}✓${NC} $target"
        else
            echo -e "  ${YELLOW}✗${NC} $target (not in backup)"
        fi
    done
    echo ""
    log_info "Encrypted files to decrypt:"
    for target in "${SENSITIVE_TARGETS[@]}"; do
        local enc_file="${backup_dir}/${target//\//_}.tar.gz.enc"
        if [ -f "$enc_file" ]; then
            echo -e "  ${GREEN}✓${NC} $target"
        else
            echo -e "  ${YELLOW}✗${NC} $target (not in backup)"
        fi
    done
    echo ""
    
    # Check manifest
    if [ -f "${backup_dir}/MANIFEST.txt" ]; then
        log_info "Backup manifest found:"
        head -10 "${backup_dir}/MANIFEST.txt"
    fi
    
    exit 0
fi

# Run restore
trap rollback ERR

create_rollback
stop_services

backup_dir=$(extract_backup "$BACKUP_FILE" "$TEMP_DIR")
restore_files "$backup_dir"
decrypt_sensitive "$backup_dir"
set_permissions

if ! verify_restore; then
    rollback
fi

if [ "$NO_RESTART" = false ]; then
    start_services
fi

cleanup

echo ""
log_info "=========================================="
log_info "Restore completed successfully!"
log_info "=========================================="
log_info "Backup restored from: $BACKUP_FILE"
log_info "Log file: $LOG_FILE"

if [ "$NO_RESTART" = true ]; then
    log_warn "Services were not restarted (--no-restart flag)"
    log_info "Run 'docker-compose up -d' to start services"
fi