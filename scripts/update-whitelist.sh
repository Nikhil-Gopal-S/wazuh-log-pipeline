#!/bin/bash
# =============================================================================
# IP Whitelist Management Script for Nginx
# =============================================================================
# This script manages the IP whitelist in the Nginx configuration.
# It allows adding, removing, and listing trusted IP addresses that bypass
# rate limiting.
#
# Usage:
#   ./update-whitelist.sh add <IP> [description]
#   ./update-whitelist.sh remove <IP>
#   ./update-whitelist.sh list
#   ./update-whitelist.sh validate
#
# Examples:
#   ./update-whitelist.sh add 203.0.113.50 "Partner API server"
#   ./update-whitelist.sh add 198.51.100.0/24 "Office network"
#   ./update-whitelist.sh remove 203.0.113.50
#   ./update-whitelist.sh list
#   ./update-whitelist.sh validate
#
# After modifications, you must reload Nginx for changes to take effect:
#   docker exec nginx-proxy nginx -s reload
#   OR
#   docker-compose restart nginx
# =============================================================================

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
WHITELIST_FILE="${PROJECT_ROOT}/deploy/nginx/conf.d/ip-whitelist.conf"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

print_usage() {
    echo "Usage: $0 <command> [arguments]"
    echo ""
    echo "Commands:"
    echo "  add <IP> [description]  Add an IP address or CIDR range to the whitelist"
    echo "  remove <IP>             Remove an IP address or CIDR range from the whitelist"
    echo "  list                    List all whitelisted IP addresses"
    echo "  validate                Validate the whitelist configuration syntax"
    echo ""
    echo "Examples:"
    echo "  $0 add 203.0.113.50 \"Partner API server\""
    echo "  $0 add 198.51.100.0/24 \"Office network\""
    echo "  $0 remove 203.0.113.50"
    echo "  $0 list"
    echo ""
    echo "Note: After modifications, reload Nginx for changes to take effect:"
    echo "  docker exec nginx-proxy nginx -s reload"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}" >&2
}

print_warning() {
    echo -e "${YELLOW}! $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# Validate IP address format (IPv4 or IPv4 with CIDR)
validate_ip() {
    local ip="$1"
    
    # IPv4 with optional CIDR notation
    local ipv4_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$'
    
    # IPv6 (simplified check)
    local ipv6_regex='^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}(/[0-9]{1,3})?$'
    
    if [[ $ip =~ $ipv4_regex ]]; then
        # Validate each octet is <= 255
        local IFS='/'
        read -ra parts <<< "$ip"
        local ip_part="${parts[0]}"
        local cidr_part="${parts[1]:-}"
        
        local IFS='.'
        read -ra octets <<< "$ip_part"
        for octet in "${octets[@]}"; do
            if (( octet > 255 )); then
                return 1
            fi
        done
        
        # Validate CIDR if present
        if [[ -n "$cidr_part" ]] && (( cidr_part > 32 )); then
            return 1
        fi
        
        return 0
    elif [[ $ip =~ $ipv6_regex ]]; then
        return 0
    else
        return 1
    fi
}

# Check if whitelist file exists
check_whitelist_file() {
    if [[ ! -f "$WHITELIST_FILE" ]]; then
        print_error "Whitelist file not found: $WHITELIST_FILE"
        print_info "Please ensure the Nginx configuration is properly set up."
        exit 1
    fi
}

# Check if IP already exists in whitelist
ip_exists() {
    local ip="$1"
    # Escape dots and slashes for grep
    local escaped_ip=$(echo "$ip" | sed 's/\./\\./g' | sed 's/\//\\\//g')
    grep -qE "^\s*${escaped_ip}\s+1;" "$WHITELIST_FILE"
}

# -----------------------------------------------------------------------------
# Command Functions
# -----------------------------------------------------------------------------

# Add an IP to the whitelist
cmd_add() {
    local ip="$1"
    local description="${2:-Added via script}"
    local date_added=$(date '+%Y-%m-%d')
    local user="${USER:-unknown}"
    
    if [[ -z "$ip" ]]; then
        print_error "IP address is required"
        print_usage
        exit 1
    fi
    
    if ! validate_ip "$ip"; then
        print_error "Invalid IP address format: $ip"
        print_info "Use IPv4 format (e.g., 203.0.113.50) or CIDR notation (e.g., 198.51.100.0/24)"
        exit 1
    fi
    
    check_whitelist_file
    
    if ip_exists "$ip"; then
        print_warning "IP address $ip is already in the whitelist"
        exit 0
    fi
    
    # Find the marker line and insert the new IP before it
    local marker="# === END TRUSTED EXTERNAL IPs ==="
    local new_entry="    ${ip} 1;  # ${description} - Added ${date_added} by ${user}"
    
    if grep -q "$marker" "$WHITELIST_FILE"; then
        # Insert before the marker using a temp file for portability
        local temp_file=$(mktemp)
        local inserted=false
        
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == *"$marker"* ]] && ! $inserted; then
                echo "$new_entry" >> "$temp_file"
                inserted=true
            fi
            echo "$line" >> "$temp_file"
        done < "$WHITELIST_FILE"
        
        mv "$temp_file" "$WHITELIST_FILE"
    else
        print_error "Could not find marker in whitelist file"
        print_info "Please add the IP manually to: $WHITELIST_FILE"
        exit 1
    fi
    
    print_success "Added $ip to the whitelist"
    print_info "Description: $description"
    print_warning "Remember to reload Nginx: docker exec nginx-proxy nginx -s reload"
}

# Remove an IP from the whitelist
cmd_remove() {
    local ip="$1"
    
    if [[ -z "$ip" ]]; then
        print_error "IP address is required"
        print_usage
        exit 1
    fi
    
    check_whitelist_file
    
    if ! ip_exists "$ip"; then
        print_warning "IP address $ip is not in the whitelist"
        exit 0
    fi
    
    # Escape special characters for sed
    local escaped_ip=$(echo "$ip" | sed 's/\./\\./g' | sed 's/\//\\\//g')
    
    # Remove the line containing the IP
    sed -i.bak "/^\s*${escaped_ip}\s\+1;/d" "$WHITELIST_FILE"
    rm -f "${WHITELIST_FILE}.bak"
    
    print_success "Removed $ip from the whitelist"
    print_warning "Remember to reload Nginx: docker exec nginx-proxy nginx -s reload"
}

# List all whitelisted IPs
cmd_list() {
    check_whitelist_file
    
    echo ""
    echo "=== IP Whitelist ==="
    echo ""
    
    # Extract and display whitelisted IPs
    echo -e "${BLUE}Built-in Trusted Networks:${NC}"
    echo "  127.0.0.1       - Localhost (IPv4)"
    echo "  ::1             - Localhost (IPv6)"
    echo "  10.0.0.0/8      - Private network (Class A)"
    echo "  172.16.0.0/12   - Private network (Class B)"
    echo "  192.168.0.0/16  - Private network (Class C)"
    echo "  172.17.0.0/16   - Docker network"
    echo "  172.18.0.0/16   - Docker network"
    echo "  172.19.0.0/16   - Docker network"
    echo "  172.20.0.0/16   - Docker network"
    echo ""
    
    echo -e "${BLUE}Custom Trusted External IPs:${NC}"
    
    # Extract custom IPs (between the markers)
    local in_section=false
    local found_custom=false
    
    while IFS= read -r line; do
        if [[ "$line" == *"=== ADD TRUSTED EXTERNAL IPs BELOW THIS LINE ==="* ]]; then
            in_section=true
            continue
        fi
        if [[ "$line" == *"=== END TRUSTED EXTERNAL IPs ==="* ]]; then
            in_section=false
            continue
        fi
        if $in_section && [[ "$line" =~ ^[[:space:]]*([0-9a-fA-F.:\/]+)[[:space:]]+1\;[[:space:]]*(#.*)? ]]; then
            local ip="${BASH_REMATCH[1]}"
            local comment="${BASH_REMATCH[2]:-}"
            echo "  $ip $comment"
            found_custom=true
        fi
    done < "$WHITELIST_FILE"
    
    if ! $found_custom; then
        echo "  (none configured)"
    fi
    
    echo ""
}

# Validate the whitelist configuration
cmd_validate() {
    check_whitelist_file
    
    print_info "Validating whitelist configuration..."
    
    # Check if nginx is available (in Docker or locally)
    if command -v docker &> /dev/null && docker ps --format '{{.Names}}' | grep -q nginx; then
        # Test configuration inside Docker container
        if docker exec nginx-proxy nginx -t 2>&1; then
            print_success "Nginx configuration is valid"
        else
            print_error "Nginx configuration has errors"
            exit 1
        fi
    elif command -v nginx &> /dev/null; then
        # Test configuration locally
        if nginx -t -c "${PROJECT_ROOT}/deploy/nginx/nginx.conf" 2>&1; then
            print_success "Nginx configuration is valid"
        else
            print_error "Nginx configuration has errors"
            exit 1
        fi
    else
        print_warning "Cannot validate: nginx not found locally or in Docker"
        print_info "Manual validation: Check the syntax of $WHITELIST_FILE"
        
        # Basic syntax check
        local errors=0
        while IFS= read -r line; do
            # Skip comments and empty lines
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// }" ]] && continue
            
            # Check for valid geo block entries
            if [[ "$line" =~ ^[[:space:]]*(default|[0-9a-fA-F.:\/]+)[[:space:]]+(0|1)\; ]]; then
                continue
            fi
            
            # Check for block markers
            if [[ "$line" =~ ^[[:space:]]*(geo|map)[[:space:]] ]] || \
               [[ "$line" =~ ^[[:space:]]*\} ]] || \
               [[ "$line" =~ ^\{ ]]; then
                continue
            fi
            
            # If we get here, the line might be invalid
            if [[ ! "$line" =~ ^[[:space:]]*$ ]]; then
                # Only flag if it looks like it should be a geo entry
                if [[ "$line" =~ [0-9]+\.[0-9]+ ]]; then
                    print_warning "Potentially invalid line: $line"
                    ((errors++))
                fi
            fi
        done < "$WHITELIST_FILE"
        
        if (( errors == 0 )); then
            print_success "Basic syntax check passed"
        else
            print_warning "Found $errors potential issues"
        fi
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    local command="${1:-}"
    
    case "$command" in
        add)
            cmd_add "$2" "$3"
            ;;
        remove)
            cmd_remove "$2"
            ;;
        list)
            cmd_list
            ;;
        validate)
            cmd_validate
            ;;
        -h|--help|help)
            print_usage
            ;;
        *)
            print_error "Unknown command: $command"
            print_usage
            exit 1
            ;;
    esac
}

main "$@"