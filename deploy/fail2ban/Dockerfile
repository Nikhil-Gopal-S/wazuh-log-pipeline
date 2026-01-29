# Fail2ban container for automated IP banning
FROM alpine:3.19

LABEL maintainer="Wazuh API Team"
LABEL description="Fail2ban for Nginx log monitoring and IP banning"

# Install fail2ban and dependencies
RUN apk add --no-cache \
    fail2ban \
    iptables \
    ip6tables \
    python3 \
    tzdata \
    && rm -rf /var/cache/apk/*

# Create required directories
RUN mkdir -p /var/run/fail2ban \
    && mkdir -p /var/log/fail2ban \
    && mkdir -p /etc/fail2ban/jail.d \
    && mkdir -p /etc/fail2ban/filter.d \
    && mkdir -p /etc/fail2ban/action.d

# Copy entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Copy jail configuration
COPY jail.local /etc/fail2ban/jail.local

# Copy filter definitions
COPY filter.d/ /etc/fail2ban/filter.d/

# Fail2ban socket and PID
VOLUME ["/var/run/fail2ban"]

# Log directory
VOLUME ["/var/log/fail2ban"]

# Configuration directory
VOLUME ["/etc/fail2ban/jail.d"]

ENTRYPOINT ["/entrypoint.sh"]
CMD ["fail2ban-server", "-f", "-x", "-v"]