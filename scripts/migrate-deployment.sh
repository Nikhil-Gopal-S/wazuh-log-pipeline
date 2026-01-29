#!/bin/bash
# =============================================================================
# Wazuh Log Pipeline Migration Script
# =============================================================================
# Migrates from existing wazuh-log-pipeline container to new deployment
# 
# Usage: ./migrate-deployment.sh [OPTIONS]
#
# Options:
#   -y, --yes       Skip confirmation prompts
#   -n, --dry-run   Simulate migration without making changes
#   -l, --local     Use existing directory (skip git clone)
#   -d, --dir DIR   Installation directory (default: /opt/wazuh-log-pipeline)
#   -m, --manager   Wazuh Manager IP (default: 10.47.5.216)
#   -h, --help      Show this help message
#
# Exit Codes:
#   0 - Success
#   1 - General error
#   2 - Container operation error
#   3 - Git operation error
#   4 - Configuration error
#   5 - Deployment error
# =============================================================================

set -euo pipefail

# Configuration
OLD_CONTAINER_NAME="wazuh-log-pipeline-agent-ingest-1"
OLD_IMAGE_NAME="sammascanner/wazuh-agent:ingets_0.2"
NEW_REPO_URL="https://github.com/Nikhil-Gopal-S/wazuh-log-pipeline.git"
WAZUH_MANAGER_IP="10.47.5.216"
WHITELIST_IP="10.47.5.216"
INSTALL_DIR="/opt/wazuh-log-pipeline"
API_PORT=9000
LOG_FILE="/var/log/wazuh-migration.log"
SKIP_CONFIRM=false
DRY_RUN=false
LOCAL_MODE=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    local color
    case $level in
        INFO)  color=$GREEN ;;
        WARN)  color=$YELLOW ;;
        ERROR) color=$RED ;;
        *)     color=$NC ;;
    esac
    
    echo -e "${color}[$timestamp] [$level] $message${NC}"
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

log_info()  { log INFO "$@"; }
log_warn()  { log WARN "$@"; }
log_error() { log ERROR "$@"; }

# Confirmation prompt
confirm() {
    local message=$1
    if [ "$SKIP_CONFIRM" = true ]; then
        log_info "Auto-confirmed: $message"
        return 0
    fi
    
    echo -e "${YELLOW}$message${NC}"
    read -p "Continue? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warn "Operation cancelled by user"
        return 1
    fi
    return 0
}

# Show help message
show_help() {
    cat << EOF
Wazuh Log Pipeline Migration Script

Usage: $0 [OPTIONS]

Options:
  -y, --yes       Skip confirmation prompts
  -n, --dry-run   Simulate migration without making changes
  -l, --local     Use existing directory (skip git clone)
  -d, --dir DIR   Installation directory (default: /opt/wazuh-log-pipeline)
  -m, --manager   Wazuh Manager IP (default: 10.47.5.216)
  -h, --help      Show this help message

Exit Codes:
  0 - Success
  1 - General error
  2 - Container operation error
  3 - Git operation error
  4 - Configuration error
  5 - Deployment error

Example:
  $0 --yes --manager 10.47.5.216 --dir /opt/wazuh-log-pipeline
  $0 --dry-run --manager 10.47.5.216  # Simulate without making changes
EOF
}

# Execute command or show what would be done in dry-run mode
run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would execute: $*"
        return 0
    else
        "$@"
    fi
}

# Comprehensive pre-flight checks
preflight_checks() {
    log_info "=== Running Pre-Flight Checks ==="
    local errors=0
    local warnings=0
    
    # 1. Check if running as root
    log_info "Checking permissions..."
    if [ "$EUID" -ne 0 ]; then
        log_error "✗ Must run as root or with sudo"
        ((errors++))
    else
        log_info "✓ Running as root"
    fi
    
    # 2. Check Docker
    log_info "Checking Docker..."
    if ! command -v docker &> /dev/null; then
        log_error "✗ Docker not installed"
        ((errors++))
    else
        DOCKER_VERSION=$(docker --version 2>/dev/null || echo "unknown")
        log_info "✓ Docker installed: $DOCKER_VERSION"
        
        # Check Docker daemon is running
        if ! docker info &> /dev/null; then
            log_error "✗ Docker daemon not running"
            ((errors++))
        else
            log_info "✓ Docker daemon running"
        fi
    fi
    
    # 3. Check Docker Compose
    log_info "Checking Docker Compose..."
    if command -v docker-compose &> /dev/null; then
        COMPOSE_VERSION=$(docker-compose --version 2>/dev/null || echo "unknown")
        log_info "✓ Docker Compose installed: $COMPOSE_VERSION"
    elif docker compose version &> /dev/null; then
        COMPOSE_VERSION=$(docker compose version 2>/dev/null || echo "unknown")
        log_info "✓ Docker Compose (plugin) installed: $COMPOSE_VERSION"
    else
        log_error "✗ Docker Compose not installed"
        ((errors++))
    fi
    
    # 4. Check Git
    log_info "Checking Git..."
    if ! command -v git &> /dev/null; then
        log_error "✗ Git not installed"
        ((errors++))
    else
        GIT_VERSION=$(git --version 2>/dev/null || echo "unknown")
        log_info "✓ Git installed: $GIT_VERSION"
    fi
    
    # 5. Check curl
    log_info "Checking curl..."
    if ! command -v curl &> /dev/null; then
        log_error "✗ curl not installed"
        ((errors++))
    else
        log_info "✓ curl installed"
    fi
    
    # 6. Check openssl
    log_info "Checking openssl..."
    if ! command -v openssl &> /dev/null; then
        log_error "✗ openssl not installed"
        ((errors++))
    else
        log_info "✓ openssl installed"
    fi
    
    # 7. Check old container status
    log_info "Checking old container..."
    if docker ps -a --format '{{.Names}}' | grep -q "^${OLD_CONTAINER_NAME}$"; then
        if docker ps --format '{{.Names}}' | grep -q "^${OLD_CONTAINER_NAME}$"; then
            log_info "✓ Old container '$OLD_CONTAINER_NAME' exists and is RUNNING"
        else
            log_info "✓ Old container '$OLD_CONTAINER_NAME' exists but is STOPPED"
        fi
    else
        log_warn "⚠ Old container '$OLD_CONTAINER_NAME' does not exist"
        ((warnings++))
    fi
    
    # 8. Check old image
    log_info "Checking old image..."
    if docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${OLD_IMAGE_NAME}$"; then
        log_info "✓ Old image '$OLD_IMAGE_NAME' exists"
    else
        log_warn "⚠ Old image '$OLD_IMAGE_NAME' does not exist"
        ((warnings++))
    fi
    
    # 9. Check installation directory
    log_info "Checking installation directory..."
    if [ -d "$INSTALL_DIR" ]; then
        log_warn "⚠ Installation directory '$INSTALL_DIR' already exists"
        ((warnings++))
    else
        PARENT_DIR=$(dirname "$INSTALL_DIR")
        if [ -d "$PARENT_DIR" ] && [ -w "$PARENT_DIR" ]; then
            log_info "✓ Parent directory '$PARENT_DIR' is writable"
        else
            log_error "✗ Cannot write to parent directory '$PARENT_DIR'"
            ((errors++))
        fi
    fi
    
    # 10. Check network connectivity to Wazuh Manager
    log_info "Checking connectivity to Wazuh Manager ($WAZUH_MANAGER_IP)..."
    if ping -c 1 -W 3 "$WAZUH_MANAGER_IP" &> /dev/null; then
        log_info "✓ Wazuh Manager is reachable (ping)"
    else
        log_warn "⚠ Cannot ping Wazuh Manager (may be blocked by firewall)"
        ((warnings++))
    fi
    
    # Check port 1514 (agent communication)
    if timeout 3 bash -c "echo > /dev/tcp/$WAZUH_MANAGER_IP/1514" 2>/dev/null; then
        log_info "✓ Wazuh Manager port 1514 is open"
    else
        log_warn "⚠ Cannot connect to Wazuh Manager port 1514"
        ((warnings++))
    fi
    
    # Check port 1515 (agent enrollment)
    if timeout 3 bash -c "echo > /dev/tcp/$WAZUH_MANAGER_IP/1515" 2>/dev/null; then
        log_info "✓ Wazuh Manager port 1515 is open"
    else
        log_warn "⚠ Cannot connect to Wazuh Manager port 1515"
        ((warnings++))
    fi
    
    # 11. Check GitHub connectivity
    log_info "Checking GitHub connectivity..."
    if curl -s --connect-timeout 5 https://github.com > /dev/null; then
        log_info "✓ GitHub is reachable"
    else
        log_error "✗ Cannot reach GitHub"
        ((errors++))
    fi
    
    # 12. Check disk space
    log_info "Checking disk space..."
    local check_dir="$INSTALL_DIR"
    if [ ! -d "$check_dir" ]; then
        check_dir=$(dirname "$INSTALL_DIR")
    fi
    AVAILABLE_SPACE=$(df -BG "$check_dir" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G' || echo "0")
    if [ "${AVAILABLE_SPACE:-0}" -ge 5 ]; then
        log_info "✓ Sufficient disk space: ${AVAILABLE_SPACE}GB available"
    else
        log_warn "⚠ Low disk space: ${AVAILABLE_SPACE}GB available (recommend 5GB+)"
        ((warnings++))
    fi
    
    # Summary
    echo ""
    log_info "=== Pre-Flight Check Summary ==="
    if [ $errors -gt 0 ]; then
        log_error "FAILED: $errors error(s), $warnings warning(s)"
        log_error "Fix the errors above before proceeding"
        return 1
    elif [ $warnings -gt 0 ]; then
        log_warn "PASSED with $warnings warning(s)"
        log_info "Review warnings above - migration can proceed"
        return 0
    else
        log_info "PASSED: All checks successful"
        return 0
    fi
}

# Show dry-run summary
show_dry_run_summary() {
    echo ""
    log_info "=============================================="
    log_info "DRY-RUN SUMMARY - No changes were made"
    log_info "=============================================="
    echo ""
    log_info "If you run without --dry-run, the script will:"
    echo ""
    log_info "1. STOP container: $OLD_CONTAINER_NAME"
    log_info "2. REMOVE container: $OLD_CONTAINER_NAME"
    log_info "3. REMOVE image: $OLD_IMAGE_NAME"
    log_info "4. CLONE repo to: $INSTALL_DIR"
    log_info "5. CONFIGURE:"
    log_info "   - MANAGER_URL=$WAZUH_MANAGER_IP"
    log_info "   - SERVER_URL=$WAZUH_MANAGER_IP"
    log_info "   - Whitelist IP: $WHITELIST_IP (ONLY this IP)"
    log_info "6. GENERATE: API key and TLS certificates"
    log_info "7. BUILD and DEPLOY: Docker containers"
    log_info "8. VERIFY: Health check on https://localhost:443"
    echo ""
    log_info "To execute for real, run:"
    log_info "  sudo $0 --yes --manager $WAZUH_MANAGER_IP"
    echo ""
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -y|--yes)
                SKIP_CONFIRM=true
                shift
                ;;
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -l|--local)
                LOCAL_MODE=true
                shift
                ;;
            -d|--dir)
                INSTALL_DIR="$2"
                shift 2
                ;;
            -m|--manager)
                WAZUH_MANAGER_IP="$2"
                WHITELIST_IP="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if running as root or with sudo
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root or with sudo"
        exit 1
    fi
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed"
        exit 1
    fi
    
    # Check Docker Compose
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        log_error "Docker Compose is not installed"
        exit 1
    fi
    
    # Check git
    if ! command -v git &> /dev/null; then
        log_error "Git is not installed"
        exit 1
    fi
    
    # Check curl
    if ! command -v curl &> /dev/null; then
        log_error "curl is not installed"
        exit 1
    fi
    
    # Check openssl
    if ! command -v openssl &> /dev/null; then
        log_error "openssl is not installed"
        exit 1
    fi
    
    log_info "All prerequisites satisfied"
}

# Step 1: Gracefully stop old container
stop_old_container() {
    log_info "=== Step 1: Gracefully stopping old container ==="
    
    # Check if container exists
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${OLD_CONTAINER_NAME}$"; then
        log_warn "Container '$OLD_CONTAINER_NAME' does not exist, skipping"
        return 0
    fi
    
    # Check if running
    if docker ps --format '{{.Names}}' | grep -q "^${OLD_CONTAINER_NAME}$"; then
        log_info "Container '$OLD_CONTAINER_NAME' is running"
        
        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY-RUN] Would stop container '$OLD_CONTAINER_NAME'"
        else
            if ! confirm "This will stop the container '$OLD_CONTAINER_NAME'. Service will be interrupted."; then
                exit 2
            fi
            
            # Graceful stop with 30 second timeout
            log_info "Attempting graceful stop (30s timeout)..."
            if ! docker stop --time 30 "$OLD_CONTAINER_NAME" 2>/dev/null; then
                log_warn "Graceful stop failed, forcing stop..."
                docker kill "$OLD_CONTAINER_NAME" 2>/dev/null || true
            fi
            
            # Wait and verify
            local max_wait=10
            local waited=0
            while docker ps --format '{{.Names}}' | grep -q "^${OLD_CONTAINER_NAME}$"; do
                if [ $waited -ge $max_wait ]; then
                    log_error "Container still running after ${max_wait}s"
                    exit 2
                fi
                sleep 1
                ((waited++))
            done
            
            log_info "Container stopped successfully"
        fi
    else
        log_info "Container '$OLD_CONTAINER_NAME' is already stopped"
    fi
    
    # Remove container
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would remove container '$OLD_CONTAINER_NAME'"
    else
        log_info "Removing container..."
        if ! docker rm -f "$OLD_CONTAINER_NAME" 2>/dev/null; then
            log_warn "Could not remove container (may already be removed)"
        fi
    fi
    
    # Check for and remove any related containers (sidecars, etc.)
    log_info "Checking for related containers..."
    local related_containers
    related_containers=$(docker ps -a --format '{{.Names}}' | grep -E "^wazuh-log-pipeline" || true)
    if [ -n "$related_containers" ]; then
        log_info "Found related containers: $related_containers"
        for container in $related_containers; do
            if [ "$DRY_RUN" = true ]; then
                log_info "[DRY-RUN] Would stop and remove related container: $container"
            else
                log_info "Stopping and removing related container: $container"
                docker stop --time 10 "$container" 2>/dev/null || docker kill "$container" 2>/dev/null || true
                docker rm -f "$container" 2>/dev/null || true
            fi
        done
    fi
    
    # Clean up any orphaned networks
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would prune orphaned networks"
    else
        log_info "Cleaning up orphaned networks..."
        docker network prune -f 2>/dev/null || true
    fi
    
    # FORCE CLEANUP: Remove any stopped containers to prevent KeyError in docker-compose 1.29.2
    # This error occurs when recreating containers if old metadata is corrupt or incompatible
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would force remove all stopped containers related to this project"
    else
        log_info "Force removing all stopped containers to prevent metadata errors..."
        docker ps -a --filter "name=wazuh-log-pipeline" -q | xargs -r docker rm -f 2>/dev/null || true
        # Also try to remove by service names if project name prefix isn't used
        docker ps -a --filter "name=wazuh-agent" -q | xargs -r docker rm -f 2>/dev/null || true
        docker ps -a --filter "name=wazuh-nginx" -q | xargs -r docker rm -f 2>/dev/null || true
        docker ps -a --filter "name=wazuh-fail2ban" -q | xargs -r docker rm -f 2>/dev/null || true
    fi

    log_info "Old container cleanup completed"
}

# Step 2: Clean up old images
cleanup_old_images() {
    log_info "=== Step 2: Cleaning up old Docker images ==="
    
    # Check if image exists
    if ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${OLD_IMAGE_NAME}$"; then
        log_warn "Image '$OLD_IMAGE_NAME' does not exist, skipping cleanup"
        return 0
    fi
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would remove Docker image '$OLD_IMAGE_NAME'"
        log_info "[DRY-RUN] Would prune dangling images"
        return 0
    fi
    
    if ! confirm "This will remove the Docker image '$OLD_IMAGE_NAME'."; then
        log_warn "Skipping image cleanup"
        return 0
    fi
    
    log_info "Removing Docker image '$OLD_IMAGE_NAME'..."
    if ! docker rmi "$OLD_IMAGE_NAME"; then
        log_warn "Failed to remove image '$OLD_IMAGE_NAME' (may be in use by other containers)"
    else
        log_info "Image '$OLD_IMAGE_NAME' removed successfully"
    fi
    
    # Prune dangling images
    log_info "Pruning dangling images..."
    docker image prune -f
    
    log_info "Image cleanup completed"
}

# Step 3: Clone new repository
clone_repository() {
    log_info "=== Step 3: Cloning new repository ==="
    
    # Check if local mode is enabled
    if [ "$LOCAL_MODE" = true ]; then
        log_info "Local mode enabled: Skipping git clone"
        if [ ! -d "$INSTALL_DIR" ]; then
            log_error "Directory '$INSTALL_DIR' does not exist (required for local mode)"
            exit 3
        fi
        
        # Verify essential files exist
        if [ ! -f "$INSTALL_DIR/docker-compose.yml" ]; then
            log_error "Verification failed: docker-compose.yml not found in '$INSTALL_DIR'"
            exit 3
        fi
        
        log_info "Using existing files in '$INSTALL_DIR'"
        return 0
    fi
    
    # Check if directory already exists
    if [ -d "$INSTALL_DIR" ]; then
        log_info "Directory '$INSTALL_DIR' already exists."
        
        # Verify it looks like a valid deployment
        if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
             log_info "Found existing deployment files. Skipping clone to avoid overwriting."
             return 0
        else
             log_warn "Directory exists but docker-compose.yml is missing."
             if [ "$DRY_RUN" = true ]; then
                 log_info "[DRY-RUN] Would remove invalid directory and re-clone"
             else
                 if confirm "Directory exists but appears invalid. Remove and re-clone?"; then
                     rm -rf "$INSTALL_DIR"
                 else
                     log_error "Cannot proceed with invalid existing directory."
                     exit 3
                 fi
             fi
        fi
    fi
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would create parent directory: $(dirname "$INSTALL_DIR")"
        log_info "[DRY-RUN] Would clone repository from '$NEW_REPO_URL' to '$INSTALL_DIR'"
        return 0
    fi
    
    # Create parent directory if needed
    mkdir -p "$(dirname "$INSTALL_DIR")"
    
    log_info "Cloning repository from '$NEW_REPO_URL'..."
    if ! git clone "$NEW_REPO_URL" "$INSTALL_DIR"; then
        log_error "Failed to clone repository"
        exit 3
    fi
    
    # Verify clone
    if [ ! -f "$INSTALL_DIR/docker-compose.yml" ]; then
        log_error "Clone verification failed: docker-compose.yml not found"
        exit 3
    fi
    
    log_info "Repository cloned successfully to '$INSTALL_DIR'"
}

# Step 4: Configure environment
configure_environment() {
    log_info "=== Step 4: Configuring environment ==="
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would create .env file with:"
        log_info "  ENVIRONMENT=test"
        log_info "  MANAGER_URL=${WAZUH_MANAGER_IP}"
        log_info "  MANAGER_PORT=1515"
        log_info "  SERVER_URL=${WAZUH_MANAGER_IP}"
        log_info "  SERVER_PORT=1514"
        log_info "  API_PORT=${API_PORT}"
        log_info "  SKIP_READINESS_CHECKS=false"
        log_info "[DRY-RUN] Would configure IP whitelist with:"
        log_info "  - 127.0.0.1 (localhost)"
        log_info "  - ::1 (localhost IPv6)"
        log_info "  - ${WHITELIST_IP} (Wazuh Manager)"
        log_info "[DRY-RUN] Would generate API key in $INSTALL_DIR/secrets/api_key.txt"
        log_info "[DRY-RUN] Would generate self-signed certificates (non-interactive mode)"
        log_info "[DRY-RUN] Certificate files: $INSTALL_DIR/deploy/nginx/certs/server.crt, server.key"
        return 0
    fi
    
    cd "$INSTALL_DIR" || exit 4
    
    # Create .env file
    log_info "Creating .env file..."
    cat > .env << EOF
# Wazuh Log Pipeline Environment Configuration
# Generated by migration script on $(date)

ENVIRONMENT=test

# Wazuh Manager Connection Settings
# MANAGER_URL: Used for agent enrollment (registration)
# SERVER_URL: Used for agent communication (sending events)
# In most cases, both point to the same Wazuh Manager IP
MANAGER_URL=${WAZUH_MANAGER_IP}
MANAGER_PORT=1515
SERVER_URL=${WAZUH_MANAGER_IP}
SERVER_PORT=1514

# API Configuration
API_PORT=${API_PORT}

# Skip readiness checks (set to true for testing)
SKIP_READINESS_CHECKS=false
EOF
    
    if [ ! -f ".env" ]; then
        log_error "Failed to create .env file"
        exit 4
    fi
    log_info ".env file created"
    
    # Configure IP whitelist - ONLY whitelist specific IPs (no broad network ranges)
    log_info "Configuring IP whitelist for ONLY ${WHITELIST_IP} (plus localhost)..."
    
    WHITELIST_FILE="$INSTALL_DIR/deploy/nginx/conf.d/ip-whitelist.conf"
    if [ -f "$WHITELIST_FILE" ]; then
        # Backup original
        cp "$WHITELIST_FILE" "${WHITELIST_FILE}.bak"
    fi
    
    # Create whitelist with ONLY specific IPs - no broad network ranges
    cat > "$WHITELIST_FILE" << EOF
# =============================================================================
# IP Whitelist Configuration for Wazuh Log Ingestion API
# =============================================================================
# SECURITY: This whitelist contains ONLY specific trusted IPs.
# NO broad network ranges (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16) are included.
#
# Generated by migration script on $(date)
# =============================================================================

geo \$whitelist {
    default 0;
    
    # Localhost - required for internal health checks
    127.0.0.1 1;
    ::1 1;
    
    # Specific trusted IP - Wazuh Manager / Test Machine
    ${WHITELIST_IP} 1;
}

map \$whitelist \$limit_key {
    0 \$binary_remote_addr;
    1 "";
}
EOF

    if [ ! -f "$WHITELIST_FILE" ]; then
        log_error "Failed to create IP whitelist file"
        exit 4
    fi
    log_info "IP whitelist configured with ONLY: 127.0.0.1, ::1, ${WHITELIST_IP}"
    
    # Generate API key
    log_info "Generating API key..."
    mkdir -p "$INSTALL_DIR/secrets"
    openssl rand -base64 32 > "$INSTALL_DIR/secrets/api_key.txt"
    chmod 600 "$INSTALL_DIR/secrets/api_key.txt"
    
    if [ ! -f "$INSTALL_DIR/secrets/api_key.txt" ]; then
        log_error "Failed to generate API key"
        exit 4
    fi
    log_info "API key generated"
    
    # Generate self-signed certificates for testing
    # Use -y flag for non-interactive mode to avoid blocking on prompts
    log_info "Generating self-signed certificates..."
    if [ -f "$INSTALL_DIR/scripts/generate-certs.sh" ]; then
        cd "$INSTALL_DIR" || exit 4
        # Ensure script is executable
        chmod +x scripts/generate-certs.sh
        # Use -y for non-interactive mode, -f to force regeneration if needed
        if bash scripts/generate-certs.sh -y; then
            log_info "Certificates generated successfully"
        else
            log_warn "Certificate generation script failed, attempting manual generation..."
            # Fallback: generate certificates manually
            mkdir -p "$INSTALL_DIR/deploy/nginx/certs"
            if openssl req -x509 -nodes \
                -days 365 \
                -newkey rsa:2048 \
                -keyout "$INSTALL_DIR/deploy/nginx/certs/server.key" \
                -out "$INSTALL_DIR/deploy/nginx/certs/server.crt" \
                -subj "/C=US/ST=California/L=San Francisco/O=Wazuh Development/OU=Security/CN=localhost" \
                -addext "subjectAltName=DNS:localhost,DNS:*.localhost,IP:127.0.0.1" 2>/dev/null; then
                chmod 600 "$INSTALL_DIR/deploy/nginx/certs/server.key"
                chmod 644 "$INSTALL_DIR/deploy/nginx/certs/server.crt"
                log_info "Certificates generated manually (fallback)"
            else
                log_error "Failed to generate certificates"
                exit 4
            fi
        fi
    else
        log_warn "Certificate generation script not found, generating manually..."
        mkdir -p "$INSTALL_DIR/deploy/nginx/certs"
        if openssl req -x509 -nodes \
            -days 365 \
            -newkey rsa:2048 \
            -keyout "$INSTALL_DIR/deploy/nginx/certs/server.key" \
            -out "$INSTALL_DIR/deploy/nginx/certs/server.crt" \
            -subj "/C=US/ST=California/L=San Francisco/O=Wazuh Development/OU=Security/CN=localhost" \
            -addext "subjectAltName=DNS:localhost,DNS:*.localhost,IP:127.0.0.1" 2>/dev/null; then
            chmod 600 "$INSTALL_DIR/deploy/nginx/certs/server.key"
            chmod 644 "$INSTALL_DIR/deploy/nginx/certs/server.crt"
            log_info "Certificates generated manually"
        else
            log_error "Failed to generate certificates"
            exit 4
        fi
    fi
    
    # Verify certificates were created
    if [ ! -f "$INSTALL_DIR/deploy/nginx/certs/server.crt" ] || [ ! -f "$INSTALL_DIR/deploy/nginx/certs/server.key" ]; then
        log_error "Certificate files not found after generation"
        exit 4
    fi
    log_info "Certificate files verified: server.crt and server.key exist"
    
    log_info "Environment configuration completed"
}

# Step 5: Deploy new containers
deploy_new_containers() {
    log_info "=== Step 5: Deploying new containers ==="
    
    # Determine docker compose command
    local compose_cmd
    if command -v docker-compose &> /dev/null; then
        compose_cmd="docker-compose"
    else
        compose_cmd="docker compose"
    fi
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would change to directory: $INSTALL_DIR"
        log_info "[DRY-RUN] Would build Docker images using: $compose_cmd build"
        log_info "[DRY-RUN] Would start containers using: $compose_cmd up -d"
        log_info "[DRY-RUN] Would wait 10 seconds for services to initialize"
        log_info "[DRY-RUN] Would check container status using: $compose_cmd ps"
        return 0
    fi
    
    cd "$INSTALL_DIR" || exit 5
    
    # Build images
    log_info "Building Docker images..."
    if ! $compose_cmd build; then
        log_error "Failed to build Docker images"
        exit 5
    fi
    log_info "Docker images built successfully"

    # Aggressive Cleanup before starting
    # log_info "Performing aggressive cleanup to prevent metadata errors..."
    # if [ "$DRY_RUN" = true ]; then
    #    log_info "[DRY-RUN] Would run: $compose_cmd down --remove-orphans -v"
    # else
        # Only remove orphans, don't kill running services if they are fine.
        # Removing -v to preserve volumes (data/logs)
        # $compose_cmd down --remove-orphans 2>/dev/null || true
    # fi

    # Workaround for docker-compose 1.29.2 'ContainerConfig' KeyError
    # We MUST stop and remove containers to avoid the recreation bug
    log_info "Stopping containers to avoid docker-compose 1.29.2 bug..."
    if [ "$DRY_RUN" = false ]; then
        # Explicitly remove the nginx container which has a fixed name and is causing issues
        if docker ps -a --format '{{.Names}}' | grep -q "^wazuh-nginx$"; then
            log_info "Force removing wazuh-nginx container..."
            docker rm -f wazuh-nginx || true
        fi
        
        # Also remove other service containers if they exist (using common project name prefixes)
        # This handles cases where docker-compose down fails to read metadata
        docker ps -a --format '{{.Names}}' | grep -E "wazuh-log-pipeline_(agent|nginx)" | xargs -r docker rm -f || true

        $compose_cmd down --remove-orphans 2>/dev/null || true
    fi
    
    # Start containers
    log_info "Starting containers..."
    # Using --force-recreate to ensure fresh containers are created
    if ! $compose_cmd up -d --remove-orphans; then
        log_error "Failed to start containers"
        exit 5
    fi
    
    log_info "Containers started, waiting for services to initialize..."
    sleep 10
    
    # Check container status
    log_info "Container status:"
    $compose_cmd ps
    
    # Check for exited containers and show logs if found
    if $compose_cmd ps | grep -q "Exit"; then
        log_error "Some containers failed to start!"
        log_info "Fetching logs for failed containers..."
        $compose_cmd logs --tail=100
        
        # Explicitly show logs for agent containers if they exist
        if $compose_cmd ps | grep -q "agent"; then
            log_info "Fetching specific agent logs..."
            $compose_cmd logs agent-ingest agent-regular
        fi
        
        exit 5
    fi
    
    log_info "Deployment completed"
}

# Step 6: Health check
health_check() {
    log_info "=== Step 6: Running health checks ==="
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Would perform health check on https://localhost:443/health/live"
        log_info "[DRY-RUN] Would verify API authentication on https://localhost:443/api/health"
        log_info "[DRY-RUN] Would display migration summary on success"
        return 0
    fi
    
    local max_attempts=30
    local attempt=1
    # Use HTTPS on port 443 (Nginx) since API is not directly exposed
    local health_url="https://localhost:443/health/live"
    
    log_info "Waiting for API to be ready (via Nginx on port 443)..."
    
    while [ $attempt -le $max_attempts ]; do
        log_info "Health check attempt $attempt/$max_attempts..."
        
        # Try health endpoint (ignore SSL cert for self-signed)
        if curl -sk "$health_url" 2>/dev/null | grep -qE "ok|healthy|live|true"; then
            log_info "Health check passed!"
            
            # Additional checks
            log_info "Running additional verification..."
            
            # Check API authentication endpoint
            if [ -f "$INSTALL_DIR/secrets/api_key.txt" ]; then
                local api_key
                api_key=$(cat "$INSTALL_DIR/secrets/api_key.txt")
                if curl -sk -H "X-API-Key: $api_key" "https://localhost:443/api/health" 2>/dev/null | grep -qE "ok|healthy|true"; then
                    log_info "API authentication working"
                else
                    log_warn "API authentication check inconclusive"
                fi
            fi
            
            log_info "=== Migration completed successfully! ==="
            log_info ""
            log_info "Summary:"
            log_info "  - Installation directory: $INSTALL_DIR"
            log_info "  - HTTPS Port: 443 (via Nginx reverse proxy)"
            log_info "  - Wazuh Manager IP: $WAZUH_MANAGER_IP"
            log_info "  - Whitelisted IPs: 127.0.0.1, ::1, $WHITELIST_IP (ONLY these specific IPs)"
            log_info "  - API Key: $INSTALL_DIR/secrets/api_key.txt"
            log_info ""
            log_info "Environment variables set in .env:"
            log_info "  - MANAGER_URL=$WAZUH_MANAGER_IP (for agent enrollment)"
            log_info "  - SERVER_URL=$WAZUH_MANAGER_IP (for agent communication)"
            log_info "  - WHITELIST_IP=$WHITELIST_IP (used in whitelist config)"
            log_info ""
            log_info "Security Note:"
            log_info "  - IP whitelist contains ONLY specific IPs (no broad network ranges)"
            log_info "  - Only 127.0.0.1, ::1, and $WHITELIST_IP can bypass rate limiting"
            log_info ""
            log_info "Next steps:"
            log_info "  1. Review docs/TEST-ENVIRONMENT-GUIDE.md for testing instructions"
            log_info "  2. Send test events to https://localhost:443/ingest"
            log_info "  3. Verify events appear in Wazuh dashboard"
            log_info ""
            
            return 0
        fi
        
        sleep 2
        ((attempt++))
    done
    
    log_error "Health check failed after $max_attempts attempts"
    log_error "Check container logs with: docker-compose -f $INSTALL_DIR/docker-compose.yml logs"
    exit 5
}

# Cleanup function for error handling
cleanup_on_error() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_error "Script failed with exit code $exit_code"
        log_error "Check log file for details: $LOG_FILE"
    fi
}

# Main execution
main() {
    # Set up error handling
    trap cleanup_on_error EXIT
    
    # Initialize log file
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE" 2>/dev/null || {
        # If we can't write to /var/log, use a local log file
        LOG_FILE="./wazuh-migration.log"
        touch "$LOG_FILE"
    }
    
    log_info "=============================================="
    log_info "Wazuh Log Pipeline Migration Script"
    log_info "=============================================="
    log_info "Started at: $(date)"
    log_info ""
    
    parse_args "$@"
    
    if [ "$DRY_RUN" = true ]; then
        log_info "*** DRY-RUN MODE - No changes will be made ***"
        log_info ""
    fi
    
    log_info "Configuration:"
    log_info "  Old Container: $OLD_CONTAINER_NAME"
    log_info "  Old Image: $OLD_IMAGE_NAME"
    log_info "  New Repo: $NEW_REPO_URL"
    log_info "  Install Dir: $INSTALL_DIR"
    log_info "  Wazuh Manager: $WAZUH_MANAGER_IP"
    log_info "  Whitelist IP: $WHITELIST_IP"
    log_info "  API Port: $API_PORT"
    log_info "  Dry-Run: $DRY_RUN"
    log_info ""
    
    # Run pre-flight checks first (always, even in dry-run mode)
    if ! preflight_checks; then
        if [ "$DRY_RUN" = true ]; then
            log_warn "Pre-flight checks failed, but continuing in dry-run mode to show what would happen"
        else
            log_error "Pre-flight checks failed. Fix the errors above before proceeding."
            exit 1
        fi
    fi
    
    echo ""
    
    # Execute migration steps
    stop_old_container
    cleanup_old_images
    clone_repository
    configure_environment
    deploy_new_containers
    health_check
    
    # Show dry-run summary if in dry-run mode
    if [ "$DRY_RUN" = true ]; then
        show_dry_run_summary
    fi
    
    log_info "Migration completed at: $(date)"
    exit 0
}

# Run main function
main "$@"