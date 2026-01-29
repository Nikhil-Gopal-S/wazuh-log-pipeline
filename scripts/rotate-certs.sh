#!/bin/bash
# =============================================================================
# TLS Certificate Rotation Script
# =============================================================================
# Rotates TLS certificates with minimal downtime
#
# Usage: ./scripts/rotate-certs.sh [options]
#   -t, --type        Certificate type: self-signed (default) or letsencrypt
#   -d, --domain      Domain name (default: localhost)
#   -e, --email       Email for Let's Encrypt
#   -c, --check       Check certificate expiration only
#   -f, --force       Force rotation even if not expiring
#   -h, --help        Show help message

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CERTS_DIR="${PROJECT_ROOT}/deploy/nginx/certs"
BACKUP_DIR="${CERTS_DIR}/backup"
NGINX_CONTAINER="wazuh-nginx"

# Certificate files
CERT_FILE="${CERTS_DIR}/server.crt"
KEY_FILE="${CERTS_DIR}/server.key"

# Default settings
CERT_TYPE="self-signed"
DOMAIN="localhost"
VALIDITY_DAYS=365
EXPIRY_THRESHOLD_DAYS=30

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

show_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -t, --type        Certificate type: self-signed (default) or letsencrypt"
    echo "  -d, --domain      Domain name (default: localhost)"
    echo "  -e, --email       Email for Let's Encrypt"
    echo "  -c, --check       Check certificate expiration only"
    echo "  -f, --force       Force rotation even if not expiring"
    echo "  -h, --help        Show this help message"
}

check_expiration() {
    if [ ! -f "$CERT_FILE" ]; then
        log_warn "No certificate found at $CERT_FILE"
        return 1
    fi
    
    local expiry_date=$(openssl x509 -enddate -noout -in "$CERT_FILE" | cut -d= -f2)
    local expiry_epoch
    local now_epoch=$(date +%s)
    
    # Handle both GNU date and BSD date (macOS)
    if date --version >/dev/null 2>&1; then
        # GNU date
        expiry_epoch=$(date -d "$expiry_date" +%s)
    else
        # BSD date (macOS)
        expiry_epoch=$(date -j -f "%b %d %T %Y %Z" "$expiry_date" +%s 2>/dev/null || \
                       date -j -f "%b  %d %T %Y %Z" "$expiry_date" +%s)
    fi
    
    local days_remaining=$(( (expiry_epoch - now_epoch) / 86400 ))
    
    log_info "Certificate expiration: $expiry_date"
    log_info "Days remaining: $days_remaining"
    
    if [ $days_remaining -lt $EXPIRY_THRESHOLD_DAYS ]; then
        log_warn "Certificate expires in less than $EXPIRY_THRESHOLD_DAYS days!"
        return 0  # Needs rotation
    else
        log_info "Certificate is valid for $days_remaining more days"
        return 1  # No rotation needed
    fi
}

backup_certs() {
    log_info "Backing up current certificates..."
    mkdir -p "$BACKUP_DIR"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    if [ -f "$CERT_FILE" ]; then
        cp "$CERT_FILE" "${BACKUP_DIR}/server.crt.${timestamp}"
    fi
    if [ -f "$KEY_FILE" ]; then
        cp "$KEY_FILE" "${BACKUP_DIR}/server.key.${timestamp}"
    fi
    
    log_info "Backup created: ${BACKUP_DIR}/*.$timestamp"
}

generate_self_signed() {
    log_info "Generating self-signed certificate for $DOMAIN..."
    
    openssl req -x509 -nodes -days $VALIDITY_DAYS -newkey rsa:2048 \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -subj "/CN=$DOMAIN/O=Wazuh API/C=US" \
        -addext "subjectAltName=DNS:$DOMAIN,DNS:localhost,IP:127.0.0.1"
    
    chmod 600 "$KEY_FILE"
    chmod 644 "$CERT_FILE"
    
    log_info "Self-signed certificate generated"
}

generate_letsencrypt() {
    if [ -z "${LETSENCRYPT_EMAIL:-}" ]; then
        log_error "Email required for Let's Encrypt (use -e option)"
        exit 1
    fi
    
    log_info "Requesting Let's Encrypt certificate for $DOMAIN..."
    
    # Create temporary directory for Let's Encrypt
    local le_dir="${CERTS_DIR}/letsencrypt"
    mkdir -p "$le_dir"
    
    # Use certbot in standalone mode
    docker run --rm \
        -v "${le_dir}:/etc/letsencrypt" \
        -p 80:80 \
        certbot/certbot certonly \
        --standalone \
        --non-interactive \
        --agree-tos \
        --email "$LETSENCRYPT_EMAIL" \
        -d "$DOMAIN"
    
    # Copy certificates to expected locations
    cp "${le_dir}/live/$DOMAIN/fullchain.pem" "$CERT_FILE"
    cp "${le_dir}/live/$DOMAIN/privkey.pem" "$KEY_FILE"
    
    chmod 600 "$KEY_FILE"
    chmod 644 "$CERT_FILE"
    
    log_info "Let's Encrypt certificate obtained"
}

validate_cert() {
    log_info "Validating new certificate..."
    
    # Check certificate is valid
    if ! openssl x509 -noout -in "$CERT_FILE" 2>/dev/null; then
        log_error "Invalid certificate file"
        return 1
    fi
    
    # Check key matches certificate
    local cert_modulus=$(openssl x509 -noout -modulus -in "$CERT_FILE" | md5sum)
    local key_modulus=$(openssl rsa -noout -modulus -in "$KEY_FILE" 2>/dev/null | md5sum)
    
    if [ "$cert_modulus" != "$key_modulus" ]; then
        log_error "Certificate and key do not match"
        return 1
    fi
    
    log_info "Certificate validation passed"
    return 0
}

reload_nginx() {
    log_info "Reloading nginx..."
    
    if docker ps --format '{{.Names}}' | grep -q "$NGINX_CONTAINER"; then
        docker exec "$NGINX_CONTAINER" nginx -t && \
        docker exec "$NGINX_CONTAINER" nginx -s reload
        log_info "Nginx reloaded successfully"
    else
        log_warn "Nginx container not running, skipping reload"
    fi
}

test_https() {
    log_info "Testing HTTPS connection..."
    
    local http_code
    http_code=$(curl -k -s -o /dev/null -w "%{http_code}" "https://localhost/health/live" 2>/dev/null || echo "000")
    
    if [ "$http_code" = "200" ]; then
        log_info "HTTPS connection test passed"
        return 0
    else
        log_warn "HTTPS connection test failed (HTTP code: $http_code, service may not be running)"
        return 1
    fi
}

rollback() {
    log_error "Rolling back to previous certificates..."
    
    local latest_backup=$(ls -t "${BACKUP_DIR}/server.crt."* 2>/dev/null | head -1)
    if [ -n "$latest_backup" ]; then
        local timestamp=$(echo "$latest_backup" | sed 's/.*\.//')
        cp "${BACKUP_DIR}/server.crt.${timestamp}" "$CERT_FILE"
        cp "${BACKUP_DIR}/server.key.${timestamp}" "$KEY_FILE"
        reload_nginx
        log_info "Rollback completed"
    else
        log_error "No backup available for rollback"
    fi
}

cleanup_old_backups() {
    log_info "Cleaning up old backups (keeping last 5)..."
    
    # Keep only the last 5 backups
    local backup_count=$(ls -1 "${BACKUP_DIR}/server.crt."* 2>/dev/null | wc -l)
    if [ "$backup_count" -gt 5 ]; then
        ls -t "${BACKUP_DIR}/server.crt."* | tail -n +6 | while read -r file; do
            local timestamp=$(echo "$file" | sed 's/.*\.//')
            rm -f "${BACKUP_DIR}/server.crt.${timestamp}"
            rm -f "${BACKUP_DIR}/server.key.${timestamp}"
        done
        log_info "Old backups cleaned up"
    fi
}

# Parse arguments
CHECK_ONLY=false
FORCE=false
LETSENCRYPT_EMAIL=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--type) CERT_TYPE="$2"; shift 2 ;;
        -d|--domain) DOMAIN="$2"; shift 2 ;;
        -e|--email) LETSENCRYPT_EMAIL="$2"; shift 2 ;;
        -c|--check) CHECK_ONLY=true; shift ;;
        -f|--force) FORCE=true; shift ;;
        -h|--help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# Create certs directory
mkdir -p "$CERTS_DIR"

# Check only mode
if [ "$CHECK_ONLY" = true ]; then
    check_expiration
    exit $?
fi

# Check if rotation needed
if [ "$FORCE" = false ]; then
    if ! check_expiration; then
        log_info "Certificate rotation not needed"
        exit 0
    fi
fi

# Perform rotation
log_info "Starting certificate rotation..."

backup_certs

case $CERT_TYPE in
    self-signed)
        generate_self_signed
        ;;
    letsencrypt)
        generate_letsencrypt
        ;;
    *)
        log_error "Unknown certificate type: $CERT_TYPE"
        exit 1
        ;;
esac

if ! validate_cert; then
    rollback
    exit 1
fi

reload_nginx

if ! test_https; then
    log_warn "HTTPS test failed, but certificate is valid"
fi

cleanup_old_backups

log_info "=========================================="
log_info "Certificate rotation completed!"
log_info "=========================================="