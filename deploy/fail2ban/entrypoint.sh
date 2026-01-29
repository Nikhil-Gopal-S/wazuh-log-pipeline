#!/bin/sh
set -e

echo "Starting Fail2ban container..."

# Ensure required directories exist
mkdir -p /var/run/fail2ban
mkdir -p /var/log/fail2ban

# Check if iptables is available
if ! command -v iptables > /dev/null 2>&1; then
    echo "WARNING: iptables not available"
else
    echo "iptables version: $(iptables --version)"
fi

# Ensure DOCKER-USER chain exists (for Docker environment)
# This chain is processed before Docker's own rules
iptables -N DOCKER-USER 2>/dev/null || true

# Clean up any stale socket
rm -f /var/run/fail2ban/fail2ban.sock

echo "Fail2ban configuration:"
fail2ban-client --version

# Execute the main command
exec "$@"