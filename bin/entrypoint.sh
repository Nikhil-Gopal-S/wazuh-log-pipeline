#!/bin/bash
# =============================================================================
# Wazuh Agent Entrypoint Script
# =============================================================================
# This script runs as root to ensure Wazuh agent binaries can start properly.
#
# Why root is required:
#   - Wazuh agent binaries (wazuh-control) require root privileges
#   - Docker Compose v1 doesn't support uid/gid on secrets
#   - Secrets are mounted as root-owned files by default
#
# This is acceptable for test/development environments. For production with
# stricter security requirements, consider using Docker Compose v2.
# =============================================================================

set -e

# =============================================================================
# Production Readiness Checks
# =============================================================================
check_production_readiness() {
    local warnings=0
    
    echo "Running production readiness checks..."
    
    # Check for self-signed certificates (only if file exists and is readable)
    if [ -f "/etc/nginx/certs/server.crt" ] && [ -r "/etc/nginx/certs/server.crt" ]; then
        ISSUER=$(openssl x509 -in /etc/nginx/certs/server.crt -issuer -noout 2>/dev/null || echo "")
        SUBJECT=$(openssl x509 -in /etc/nginx/certs/server.crt -subject -noout 2>/dev/null || echo "")
        if [ "$ISSUER" = "$SUBJECT" ]; then
            echo "WARNING: Self-signed certificate detected!"
            echo "         For production, deploy a valid CA-signed certificate."
            ((warnings++)) || true
        fi
    fi
    
    # Check for default/weak API key
    # First check if secret file exists and is readable
    if [ -f "/run/secrets/api_key" ]; then
        if [ -r "/run/secrets/api_key" ]; then
            API_KEY=$(cat /run/secrets/api_key 2>/dev/null || echo "")
            if [ -n "$API_KEY" ]; then
                if [ ${#API_KEY} -lt 32 ]; then
                    echo "WARNING: API key is less than 32 characters!"
                    echo "         Use a stronger API key for production."
                    ((warnings++)) || true
                fi
                if [ "$API_KEY" = "changeme" ] || [ "$API_KEY" = "test" ] || [ "$API_KEY" = "development" ]; then
                    echo "ERROR: Default/test API key detected!"
                    echo "       Generate a secure API key before production deployment."
                    ((warnings++)) || true
                fi
            else
                echo "WARNING: API key file exists but is empty or unreadable"
                ((warnings++)) || true
            fi
        else
            echo "WARNING: API key file exists but is not readable by current user"
            echo "         Check secret file permissions"
            ((warnings++)) || true
        fi
    elif [ -n "${API_KEY:-}" ]; then
        # Fallback: check API_KEY environment variable
        echo "INFO: Using API_KEY from environment variable"
        if [ ${#API_KEY} -lt 32 ]; then
            echo "WARNING: API key is less than 32 characters!"
            ((warnings++)) || true
        fi
    else
        echo "WARNING: No API key configured (neither secret file nor environment variable)"
        echo "         API authentication will fail without a valid API key"
        ((warnings++)) || true
    fi
    
    # Check environment variable
    if [ "${ENVIRONMENT:-development}" = "production" ]; then
        echo "Production environment detected."
        if [ $warnings -gt 0 ]; then
            echo "WARNING: $warnings production readiness issue(s) found!"
            echo "         Review and fix before exposing to internet."
        else
            echo "All production readiness checks passed."
        fi
    fi
    
    # Return success even with warnings - don't block container startup
    return 0
}

# Run checks if not in CI/test mode
if [ "${SKIP_READINESS_CHECKS:-false}" != "true" ]; then
    # Run checks but don't fail on errors - just warn
    check_production_readiness || echo "WARNING: Production readiness checks encountered an error"
fi

# Generate random agent name suffix
RANDOM_NAME=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 10)

# Set environment variables with defaults
export MANAGER_URL="${MANAGER_URL:-localhost}"
export MANAGER_PORT="${MANAGER_PORT:-1515}"
export SERVER_URL="${SERVER_URL:-localhost}"
export SERVER_PORT="${SERVER_PORT:-1514}"
if [ -n "$NAME" ]; then
  export NAME="$NAME"
else
  export NAME="agent-${RANDOM_NAME}"
fi
echo "Agent Name: $NAME"
export GROUP="${GROUP:-default}"
export ENROL_TOKEN="${ENROL_TOKEN:-}"

# Setup enrollment token for agent registration
echo "Setting up registration key..."
if [ -n "$ENROL_TOKEN" ]; then
  echo -n "$ENROL_TOKEN" > /var/ossec/etc/authd.pass
else
  rm -f /var/ossec/etc/authd.pass 2>/dev/null || true
fi

# Generate ossec.conf from template
echo "Setting up configuration..."
envsubst < "/opt/ossec/ossec.tpl" > "/var/ossec/etc/ossec.conf"

# Start Wazuh agent
echo "Starting Wazuh Agent..."
/var/ossec/bin/wazuh-control start

# Start the ingest API (runs as current user - wazuh)
echo "Starting Ingest API..."
/var/ossec/wodles/api/start.sh &

# Start health and readiness endpoints (runs as current user - wazuh)
echo "Starting Health and Readiness endpoints..."
cd /web && ./ready.sh &

# Keep container running by tailing logs
echo "Container startup complete. Tailing logs..."
tail -f /var/ossec/logs/* 2>/dev/null || tail -f /dev/null
