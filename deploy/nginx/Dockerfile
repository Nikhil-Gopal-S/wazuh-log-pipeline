# Nginx Reverse Proxy for Wazuh Log Ingestion API
# Production-ready with security hardening

FROM nginx:1.25-alpine

LABEL maintainer="Wazuh Security Team"
LABEL version="1.0"
LABEL description="Secure Nginx reverse proxy for Wazuh log ingestion API"

# Install required packages for health checks
RUN apk add --no-cache \
    curl \
    && rm -rf /var/cache/apk/*

# Create non-root user for nginx
# Note: nginx:alpine already has nginx user, but we ensure proper setup
RUN addgroup -g 101 -S nginx 2>/dev/null || true \
    && adduser -S -D -H -u 101 -h /var/cache/nginx -s /sbin/nologin -G nginx -g nginx nginx 2>/dev/null || true

# Remove default nginx configuration
RUN rm -rf /etc/nginx/conf.d/default.conf \
    && rm -rf /etc/nginx/nginx.conf

# Create required directories with proper permissions
RUN mkdir -p /var/cache/nginx/client_temp \
    && mkdir -p /var/cache/nginx/proxy_temp \
    && mkdir -p /var/cache/nginx/fastcgi_temp \
    && mkdir -p /var/cache/nginx/uwsgi_temp \
    && mkdir -p /var/cache/nginx/scgi_temp \
    && mkdir -p /var/run/nginx \
    && mkdir -p /etc/nginx/ssl \
    && mkdir -p /etc/nginx/conf.d

# Set ownership for nginx directories
RUN chown -R nginx:nginx /var/cache/nginx \
    && chown -R nginx:nginx /var/run/nginx \
    && chown -R nginx:nginx /etc/nginx \
    && chown -R nginx:nginx /var/log/nginx

# Create pid file location writable by nginx user
RUN touch /var/run/nginx/nginx.pid \
    && chown nginx:nginx /var/run/nginx/nginx.pid

# Copy main nginx configuration
COPY nginx.conf /etc/nginx/nginx.conf

# Copy additional configuration files (will be added in subsequent tasks)
# COPY conf.d/ /etc/nginx/conf.d/

# Expose HTTPS port only (no HTTP for security)
EXPOSE 443

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f -k https://localhost:443/health/live || exit 1

# Switch to non-root user
USER nginx

# Start nginx in foreground
CMD ["nginx", "-g", "daemon off;"]
