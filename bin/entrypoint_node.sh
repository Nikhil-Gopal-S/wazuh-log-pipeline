#!/bin/bash
# =============================================================================
# Wazuh Agent Node Entrypoint Script
# =============================================================================
# This script runs as the non-root 'wazuh' user (UID 1000).
# The container is configured to run as the wazuh user via the Dockerfile's
# USER directive, so no privilege escalation (gosu/sudo) is needed or available.
#
# This is a lightweight version of the entrypoint script for node deployments
# that does not include the ingest API.
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

# Ensure permissions are correct (since we run as root)
chown wazuh:wazuh /var/ossec/etc/ossec.conf
if [ -f "/var/ossec/etc/authd.pass" ]; then
    chown wazuh:wazuh /var/ossec/etc/authd.pass
    chmod 640 /var/ossec/etc/authd.pass
fi

# Start Wazuh agent
echo "Starting Wazuh Agent..."
# Allow agent start to fail without exiting script (so API can still start)
/var/ossec/bin/wazuh-control start || echo "WARNING: Wazuh Agent failed to start"

# Start health and readiness endpoints (runs as current user - wazuh)
echo "Starting Health and Readiness endpoints..."
cd /web && ./ready.sh &

# Keep container running by tailing logs
echo "Container startup complete. Tailing logs..."
tail -f /var/ossec/logs/* 2>/dev/null || tail -f /dev/null
