# =============================================================================
# Wazuh Log Ingestion API - Multi-Stage Dockerfile
# =============================================================================
# Stage 1: Builder - Compile Python dependencies into wheels
# Stage 2: Final - Production image with Wazuh agent and pre-built packages
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: Builder - Build Python wheels
# -----------------------------------------------------------------------------
FROM python:3.11-slim AS builder

# Labels for builder stage
LABEL stage="builder"

WORKDIR /build

# Install build dependencies for compiling Python packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    gcc \
    g++ \
    libffi-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements file
COPY api/requirements.txt .

# Build wheels for all dependencies (no cache to reduce size)
RUN pip wheel --no-cache-dir --wheel-dir /wheels -r requirements.txt

# -----------------------------------------------------------------------------
# Stage 2: Final - Production image
# -----------------------------------------------------------------------------
FROM debian:trixie-slim AS final

# =============================================================================
# Image Labels (OCI Standard)
# =============================================================================
LABEL maintainer="Wazuh API Team"
LABEL version="1.0.0"
LABEL description="Wazuh Log Ingestion API - Secure log ingestion service"
LABEL org.opencontainers.image.title="Wazuh Log Ingestion API"
LABEL org.opencontainers.image.description="FastAPI-based log ingestion service for Wazuh SIEM"
LABEL org.opencontainers.image.version="1.0.0"
LABEL org.opencontainers.image.vendor="Wazuh"
LABEL org.opencontainers.image.licenses="GPL-2.0"
LABEL org.opencontainers.image.source="https://github.com/wazuh/wazuh-api"

# =============================================================================
# Install Python and minimal runtime dependencies
# =============================================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# =============================================================================
# Copy and install pre-built Python wheels from builder stage
# =============================================================================
COPY --from=builder /wheels /wheels
RUN pip3 install --no-cache-dir --break-system-packages /wheels/* \
    && rm -rf /wheels

# =============================================================================
# Install system utilities required for Wazuh and runtime
# =============================================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    procps \
    curl \
    apt-transport-https \
    ca-certificates \
    gnupg2 \
    inotify-tools \
    gettext-base \
    gosu \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# =============================================================================
# Install Wazuh Agent
# =============================================================================
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Add Wazuh GPG key and repository
RUN curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | \
    gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import \
    && chmod 644 /usr/share/keyrings/wazuh.gpg

RUN echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" | \
    tee -a /etc/apt/sources.list.d/wazuh.list

# Install Wazuh agent (version can be specified via build arg)
ARG WAZUH_AGENT_VERSION
RUN apt-get update && \
    if [ -n "$WAZUH_AGENT_VERSION" ]; then \
        apt-get install -y --no-install-recommends wazuh-agent="$WAZUH_AGENT_VERSION"; \
    else \
        apt-get install -y --no-install-recommends wazuh-agent; \
    fi \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# =============================================================================
# Copy application files
# =============================================================================
COPY api /var/ossec/wodles/api/
COPY bin/entrypoint.sh /
COPY config /opt/ossec
COPY web /web

# =============================================================================
# Set permissions and security hardening
# =============================================================================
# Make scripts executable
RUN chmod +x /web/ready.sh && chmod +x /entrypoint.sh

# Set ownership for non-root user (wazuh user created by wazuh-agent package)
RUN chown -R wazuh:wazuh /var/ossec/wodles/api /web

# =============================================================================
# Security: Switch to non-root user
# =============================================================================
USER wazuh

# =============================================================================
# Container configuration
# =============================================================================
# Health check for container orchestration
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8000/health/live || exit 1

# Default entrypoint
ENTRYPOINT ["/entrypoint.sh"]
