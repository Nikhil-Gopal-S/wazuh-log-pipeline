#!/bin/bash
# =============================================================================
# Wazuh Agent Entrypoint Script
# =============================================================================
# This script runs as the non-root 'wazuh' user (UID 1000).
# The container is configured to run as the wazuh user via the Dockerfile's
# USER directive, so no privilege escalation (gosu/sudo) is needed or available.
#
# Prerequisites (handled in Dockerfile at build time):
#   - All directories under /var/ossec are owned by wazuh:wazuh
#   - All directories under /opt/ossec are readable by wazuh
#   - The /web directory is owned by wazuh:wazuh
#
# Note: If using mounted volumes, ensure the host directories have appropriate
# permissions for UID 1000 (wazuh user) before starting the container.
# =============================================================================

set -e

# =============================================================================
# Production Readiness Checks
# =============================================================================
check_production_readiness() {
    local warnings=0
    
    echo "Running production readiness checks..."
    
    # Check for self-signed certificates
    if [ -f "/etc/nginx/certs/server.crt" ]; then
        ISSUER=$(openssl x509 -in /etc/nginx/certs/server.crt -issuer -noout 2>/dev/null || echo "")
        SUBJECT=$(openssl x509 -in /etc/nginx/certs/server.crt -subject -noout 2>/dev/null || echo "")
        if [ "$ISSUER" = "$SUBJECT" ]; then
            echo "WARNING: Self-signed certificate detected!"
            echo "         For production, deploy a valid CA-signed certificate."
            ((warnings++))
        fi
    fi
    
    # Check for default/weak API key
    if [ -f "/run/secrets/api_key" ]; then
        API_KEY=$(cat /run/secrets/api_key)
        if [ ${#API_KEY} -lt 32 ]; then
            echo "WARNING: API key is less than 32 characters!"
            echo "         Use a stronger API key for production."
            ((warnings++))
        fi
        if [ "$API_KEY" = "changeme" ] || [ "$API_KEY" = "test" ] || [ "$API_KEY" = "development" ]; then
            echo "ERROR: Default/test API key detected!"
            echo "       Generate a secure API key before production deployment."
            ((warnings++))
        fi
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
}

# Run checks if not in CI/test mode
if [ "${SKIP_READINESS_CHECKS:-false}" != "true" ]; then
    check_production_readiness
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
