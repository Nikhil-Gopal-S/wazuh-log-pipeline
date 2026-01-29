# Wazuh Log Ingestion Pipeline - Deployment Guide

**Version:** 1.0.0  
**Last Updated:** 2026-01-29  
**Status:** Production Ready

---

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Quick Start](#3-quick-start)
4. [Detailed Deployment Steps](#4-detailed-deployment-steps)
5. [Verification Steps](#5-verification-steps)
6. [Configuration Reference](#6-configuration-reference)
7. [Security Features](#7-security-features)
8. [Common Issues and Solutions](#8-common-issues-and-solutions)
9. [Maintenance](#9-maintenance)

---

## 1. Overview

### What This Project Does

The Wazuh Log Ingestion Pipeline provides a secure, production-ready API for ingesting security logs into a Wazuh SIEM manager. It accepts logs via HTTPS API endpoints and forwards them to Wazuh for analysis, correlation, and alerting.

### Key Features

- **RESTful API** for log ingestion (single and batch)
- **TLS 1.2/1.3 encryption** for all communications
- **API key authentication** for access control
- **Rate limiting** to prevent abuse
- **Fail2ban integration** for automated IP blocking
- **Docker-based deployment** for consistency and isolation
- **Health check endpoints** for monitoring

### Security Features Implemented

| Feature | Description |
|---------|-------------|
| TLS Encryption | All traffic encrypted with TLS 1.2/1.3 |
| API Key Authentication | Mandatory authentication for all API endpoints |
| Rate Limiting | 100 req/s with burst protection |
| Fail2ban | Automated IP banning for abuse |
| Non-root Containers | All containers run as non-root users |
| Network Isolation | Internal services isolated from external access |
| Docker Secrets | Sensitive data stored securely |
| Security Headers | HSTS and X-Content-Type-Options |

### Architecture Diagram

```
                                    ┌─────────────────────────────────────────┐
                                    │           EXTERNAL NETWORK              │
                                    │                                         │
    Internet ──────────────────────►│  ┌─────────────────────────────────┐   │
         │                          │  │         Nginx Reverse Proxy      │   │
         │                          │  │  ┌─────────────────────────────┐ │   │
         │  HTTPS (443)             │  │  │ • TLS Termination           │ │   │
         └─────────────────────────►│  │  │ • Rate Limiting             │ │   │
                                    │  │  │ • Security Headers          │ │   │
                                    │  │  │ • Request Filtering         │ │   │
                                    │  │  └─────────────────────────────┘ │   │
                                    │  └──────────────┬──────────────────┘   │
                                    │                 │                       │
                                    └─────────────────┼───────────────────────┘
                                                      │
                                    ┌─────────────────┼───────────────────────┐
                                    │                 │   INTERNAL NETWORK    │
                                    │                 ▼                       │
                                    │  ┌─────────────────────────────────┐   │
                                    │  │       Agent Ingest Service       │   │
                                    │  │  ┌─────────────────────────────┐ │   │
                                    │  │  │ • FastAPI Application       │ │   │
                                    │  │  │ • API Key Validation        │ │   │
                                    │  │  │ • Input Validation          │ │   │
                                    │  │  │ • Wazuh Socket Connection   │ │   │
                                    │  │  └─────────────────────────────┘ │   │
                                    │  └──────────────┬──────────────────┘   │
                                    │                 │                       │
                                    │                 ▼                       │
                                    │  ┌─────────────────────────────────┐   │
                                    │  │        Wazuh Manager            │   │
                                    │  │  (External - not in compose)    │   │
                                    │  └─────────────────────────────────┘   │
                                    │                                         │
                                    │  ┌─────────────────────────────────┐   │
                                    │  │          Fail2ban               │   │
                                    │  │  • Monitors Nginx logs          │   │
                                    │  │  • Bans malicious IPs           │   │
                                    │  └─────────────────────────────────┘   │
                                    │                                         │
                                    └─────────────────────────────────────────┘
```

---

## 2. Prerequisites

### Docker Requirements

| Component | Minimum Version | Recommended |
|-----------|-----------------|-------------|
| Docker | 20.10+ | 24.0+ |
| Docker Compose | 2.0+ | 2.20+ |

Verify your versions:

```bash
docker --version
docker compose version
```

### System Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU | 2 cores | 4 cores |
| RAM | 2 GB | 4 GB |
| Disk | 10 GB | 20 GB |
| OS | Linux (kernel 4.x+) | Ubuntu 22.04 LTS |

### Network Requirements

| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 443 | TCP | Inbound | HTTPS API endpoint |
| 80 | TCP | Inbound | HTTP redirect to HTTPS |
| 1514 | TCP | Outbound | Wazuh agent communication |
| 1515 | TCP | Outbound | Wazuh enrollment |

### Required Tools

Ensure the following tools are installed:

```bash
# Check for required tools
which openssl curl docker
```

Install if missing:

```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install -y openssl curl docker.io docker-compose-plugin

# macOS (with Homebrew)
brew install openssl curl docker docker-compose
```

---

## 3. Quick Start

For experienced users, here's the fastest path to deployment:

```bash
# 1. Clone the repository
git clone <repository-url>
cd wazuh-log-pipeline

# 2. Initialize secrets (generates API key)
./scripts/init-secrets.sh

# 3. Generate TLS certificates
./scripts/generate-certs.sh

# 4. Configure environment
cp .env.example .env
# Edit .env with your Wazuh manager details

# 5. Start services
docker compose up -d

# 6. Verify deployment
curl -k https://localhost/health/live
```

---

## 4. Detailed Deployment Steps

### Step 1: Clone and Prepare

```bash
# Clone the repository
git clone <repository-url>
cd wazuh-log-pipeline

# Verify directory structure
ls -la
```

Expected structure:

```
wazuh-log-pipeline/
├── api/                    # API application code
├── bin/                    # Entrypoint scripts
├── config/                 # Configuration templates
├── deploy/
│   ├── nginx/              # Nginx configuration
│   └── fail2ban/           # Fail2ban configuration
├── docs/                   # Documentation
├── scripts/                # Utility scripts
├── secrets/                # Secret files (gitignored)
├── docker-compose.yml      # Main compose file
├── Dockerfile              # API container image
└── Dockerfile.agent        # Agent container image
```

### Step 2: Configure Secrets

The API requires an API key for authentication. Generate it securely:

```bash
# Run the initialization script
./scripts/init-secrets.sh
```

This script will:
- Create the `secrets/` directory with proper permissions
- Generate a 64-character hex API key
- Set file permissions to 600 (owner read/write only)

**Manual alternative:**

```bash
# Create secrets directory
mkdir -p secrets
chmod 700 secrets

# Generate API key
openssl rand -hex 32 > secrets/api_key.txt
chmod 600 secrets/api_key.txt
```

**Important:** Save the API key securely. You'll need it to authenticate API requests.

```bash
# View your API key
cat secrets/api_key.txt
```

### Step 3: Generate TLS Certificates

For development/testing, generate self-signed certificates:

```bash
./scripts/generate-certs.sh
```

For production, use certificates from a trusted CA:

```bash
# Copy your CA-signed certificates
cp /path/to/your/certificate.crt deploy/nginx/certs/server.crt
cp /path/to/your/private.key deploy/nginx/certs/server.key

# Set proper permissions
chmod 644 deploy/nginx/certs/server.crt
chmod 600 deploy/nginx/certs/server.key
```

**Let's Encrypt (optional):**

```bash
# Use the rotation script with Let's Encrypt
./scripts/rotate-certs.sh --type letsencrypt --domain your-domain.com --email admin@your-domain.com
```

### Step 4: Configure Environment

Create and configure the environment file:

```bash
# Copy example configuration
cp .env.example .env

# Edit with your settings
nano .env
```

**Required environment variables:**

```bash
# Wazuh Manager Connection
MANAGER_URL=your-wazuh-manager.example.com
MANAGER_PORT=1515
SERVER_URL=your-wazuh-manager.example.com
SERVER_PORT=1514

# Agent Configuration
NAME=agent-ingest
GROUP=default
ENROL_TOKEN=your-enrollment-token

# Optional: Wazuh Agent Version
WAZUH_AGENT_VERSION=4.7.0-1
```

### Step 5: Build Images

Build the Docker images:

```bash
# Build all images
docker compose build

# Or build with no cache for fresh build
docker compose build --no-cache
```

### Step 6: Start Services

Start all services:

```bash
# Start in detached mode
docker compose up -d

# View logs
docker compose logs -f
```

Services started:
- **nginx** - Reverse proxy (ports 80, 443)
- **agent-ingest** - API service (internal only)
- **agent-regular** - Regular Wazuh agent (internal only)
- **fail2ban** - IP banning service

### Step 7: Verify Deployment

Run the verification checks:

```bash
# Check all containers are running
docker compose ps

# Expected output:
# NAME              STATUS    PORTS
# wazuh-nginx       Up        0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp
# agent-ingest      Up        (internal)
# agent-regular     Up        (internal)
# wazuh-fail2ban    Up        (host network)
```

---

## 5. Verification Steps

### Health Check Commands

```bash
# 1. Liveness probe (no auth required)
curl -k https://localhost/health/live
# Expected: {"status":"alive"}

# 2. Readiness probe (no auth required)
curl -k https://localhost/health/ready
# Expected: {"status":"ready","wazuh_socket":"connected"}

# 3. Full health check (requires API key)
API_KEY=$(cat secrets/api_key.txt)
curl -k -H "X-API-Key: $API_KEY" https://localhost/api/health
# Expected: {"status":"healthy","service":"wazuh-api","version":"1.0.0",...}
```

### Log Verification

```bash
# Check Nginx access logs
docker exec wazuh-nginx cat /var/log/nginx/access.log

# Check API logs
docker compose logs agent-ingest

# Check Fail2ban status
docker exec wazuh-fail2ban fail2ban-client status
```

### Security Verification

```bash
# 1. Verify TLS configuration
openssl s_client -connect localhost:443 -tls1_2 < /dev/null 2>/dev/null | grep "Protocol\|Cipher"

# 2. Verify authentication is required
curl -k https://localhost/api/health
# Expected: 401 Unauthorized

# 3. Verify rate limiting
for i in {1..150}; do curl -k -s -o /dev/null -w "%{http_code}\n" https://localhost/health/live; done | sort | uniq -c
# Should see some 429 responses after burst limit

# 4. Check security headers
curl -k -I https://localhost/health/live 2>/dev/null | grep -E "Strict-Transport|X-Content-Type"
```

### API Testing

```bash
# Set API key
API_KEY=$(cat secrets/api_key.txt)

# Test single event ingestion
curl -k -X PUT https://localhost/api/ \
  -H "X-API-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "timestamp": "2024-01-15T10:30:00Z",
    "source": "test-server",
    "message": "Test log message",
    "level": "info"
  }'

# Test batch ingestion
curl -k -X PUT https://localhost/api/batch \
  -H "X-API-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "events": [
      {"timestamp": "2024-01-15T10:30:00Z", "source": "server1", "message": "Event 1"},
      {"timestamp": "2024-01-15T10:30:01Z", "source": "server1", "message": "Event 2"}
    ]
  }'
```

---

## 6. Configuration Reference

### Environment Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `MANAGER_URL` | Wazuh manager hostname | `localhost` | Yes |
| `MANAGER_PORT` | Wazuh enrollment port | `1515` | No |
| `SERVER_URL` | Wazuh server hostname | `localhost` | Yes |
| `SERVER_PORT` | Wazuh agent port | `1514` | No |
| `NAME` | Agent name | `agent-ingest` | No |
| `GROUP` | Agent group | `default` | No |
| `ENROL_TOKEN` | Enrollment token | - | Yes |
| `API_KEY` | API authentication key | - | Yes* |
| `WAZUH_AGENT_VERSION` | Specific agent version | Latest | No |
| `LOG_LEVEL` | Logging level | `INFO` | No |
| `ENVIRONMENT` | Environment name | `production` | No |

*API_KEY can be provided via Docker secret (preferred) or environment variable.

### Docker Compose Services

| Service | Image | Ports | Networks | Purpose |
|---------|-------|-------|----------|---------|
| `nginx` | Custom | 80, 443 | external, internal | Reverse proxy |
| `agent-ingest` | Custom | None (internal) | internal | API service |
| `agent-regular` | Custom | None (internal) | internal | Regular agent |
| `fail2ban` | Custom | Host network | host | IP banning |

### Nginx Configuration Files

| File | Purpose |
|------|---------|
| [`nginx.conf`](../deploy/nginx/nginx.conf) | Main configuration |
| [`conf.d/default.conf`](../deploy/nginx/conf.d/default.conf) | Server blocks |
| [`conf.d/ssl.conf`](../deploy/nginx/conf.d/ssl.conf) | TLS settings |
| [`conf.d/rate-limiting.conf`](../deploy/nginx/conf.d/rate-limiting.conf) | Rate limits |
| [`conf.d/ip-whitelist.conf`](../deploy/nginx/conf.d/ip-whitelist.conf) | IP whitelist |
| [`conf.d/logging.conf`](../deploy/nginx/conf.d/logging.conf) | Log formats |

### Fail2ban Configuration

| File | Purpose |
|------|---------|
| [`jail.local`](../deploy/fail2ban/jail.local) | Jail definitions |
| [`filter.d/wazuh-api-auth.conf`](../deploy/fail2ban/filter.d/wazuh-api-auth.conf) | Auth failure filter |
| [`filter.d/wazuh-api-ratelimit.conf`](../deploy/fail2ban/filter.d/wazuh-api-ratelimit.conf) | Rate limit filter |
| [`filter.d/wazuh-api-scanner.conf`](../deploy/fail2ban/filter.d/wazuh-api-scanner.conf) | Scanner detection |

**Fail2ban Jails:**

| Jail | Trigger | Ban Time |
|------|---------|----------|
| `wazuh-api-auth` | 5 auth failures in 5 min | 1 hour |
| `wazuh-api-ratelimit` | 20 rate limits in 1 min | 30 min |
| `wazuh-api-badrequest` | 10 bad requests in 5 min | 30 min |
| `wazuh-api-scanner` | 10 probes in 1 min | 2 hours |

---

## 7. Security Features

### Non-root Containers

All containers run as non-root users:

- **nginx**: Runs as `nginx` user
- **agent-ingest**: Runs as `wazuh` user
- **agent-regular**: Runs as `wazuh` user
- **fail2ban**: Requires `NET_ADMIN` capability for iptables

### Network Isolation

```
┌─────────────────────────────────────────────────────────────┐
│                    wazuh-external network                    │
│  ┌─────────┐                                                │
│  │  Nginx  │◄─── Port 443 (only exposed port)               │
│  └────┬────┘                                                │
└───────┼─────────────────────────────────────────────────────┘
        │
┌───────┼─────────────────────────────────────────────────────┐
│       ▼            wazuh-internal network                    │
│  ┌─────────┐      ┌─────────┐                               │
│  │   API   │      │  Agent  │                               │
│  │(ingest) │      │(regular)│                               │
│  └─────────┘      └─────────┘                               │
│                   Internal only, no external access          │
└─────────────────────────────────────────────────────────────┘
```

### Rate Limiting

- **Global limit**: 100 requests/second per IP
- **Burst allowance**: Up to 200 requests in burst
- **Response**: HTTP 429 Too Many Requests

### API Key Authentication

- Required for all endpoints except health probes
- Stored securely in Docker secrets
- Compared using constant-time comparison (prevents timing attacks)
- Logged authentication failures (for fail2ban)

### TLS Encryption

- **Protocols**: TLS 1.2 and TLS 1.3 only
- **Ciphers**: ECDHE with AES-GCM and ChaCha20
- **HSTS**: Enabled with 1-year max-age
- **Session tickets**: Disabled for forward secrecy

### Fail2ban Protection

Automated IP banning based on:
- Authentication failures (401/403)
- Rate limit violations (429)
- Bad requests (400)
- Scanning/probing attempts (404 on sensitive paths)

---

## 8. Common Issues and Solutions

### Port Conflicts

**Problem:** Port 80 or 443 already in use

```bash
# Check what's using the ports
sudo lsof -i :80
sudo lsof -i :443
```

**Solution:**

```bash
# Stop conflicting service
sudo systemctl stop apache2  # or nginx, etc.

# Or change ports in docker-compose.yml
ports:
  - "8443:443"
  - "8080:80"
```

### Permission Issues

**Problem:** Permission denied on secrets or certificates

```bash
# Fix secrets permissions
chmod 700 secrets/
chmod 600 secrets/api_key.txt

# Fix certificate permissions
chmod 644 deploy/nginx/certs/server.crt
chmod 600 deploy/nginx/certs/server.key
```

**Problem:** Container can't write to volumes

```bash
# Check volume ownership
docker compose exec agent-ingest ls -la /var/ossec/

# Fix ownership if needed (run as root temporarily)
docker compose exec -u root agent-ingest chown -R wazuh:wazuh /var/ossec/
```

### Certificate Errors

**Problem:** SSL certificate verification failed

```bash
# For self-signed certificates, use -k flag
curl -k https://localhost/health/live

# Check certificate details
openssl x509 -in deploy/nginx/certs/server.crt -text -noout
```

**Problem:** Certificate expired

```bash
# Check expiration
./scripts/rotate-certs.sh --check

# Rotate certificates
./scripts/rotate-certs.sh --force
```

### Connection Refused

**Problem:** Connection refused to API

```bash
# Check if containers are running
docker compose ps

# Check container logs
docker compose logs nginx
docker compose logs agent-ingest

# Verify network connectivity
docker compose exec nginx ping agent-ingest
```

**Problem:** Wazuh socket not available

```bash
# Check if Wazuh agent is running
docker compose exec agent-ingest /var/ossec/bin/wazuh-control status

# Check socket exists
docker compose exec agent-ingest ls -la /var/ossec/queue/sockets/
```

### Fail2ban Issues

**Problem:** Fail2ban not banning IPs

```bash
# Check fail2ban status
docker exec wazuh-fail2ban fail2ban-client status

# Check specific jail
docker exec wazuh-fail2ban fail2ban-client status wazuh-api-auth

# Check logs
docker exec wazuh-fail2ban cat /var/log/fail2ban/fail2ban.log
```

**Problem:** Legitimate IP banned

```bash
# Unban specific IP
docker exec wazuh-fail2ban fail2ban-client set wazuh-api-auth unbanip <IP>

# Unban all IPs
docker exec wazuh-fail2ban fail2ban-client unban --all
```

---

## 9. Maintenance

### Backup Procedures

**Configuration Backup:**

```bash
# Run backup script
./scripts/backup.sh

# Manual backup
BACKUP_DIR="backups/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

# Backup configuration
cp -r deploy/ "$BACKUP_DIR/"
cp docker-compose.yml "$BACKUP_DIR/"
cp .env "$BACKUP_DIR/"

# Backup secrets (encrypted)
tar czf - secrets/ | gpg --symmetric --cipher-algo AES256 > "$BACKUP_DIR/secrets.tar.gz.gpg"
```

**Volume Backup:**

```bash
# Backup named volumes
docker run --rm \
  -v agent-ingest-ossec-data:/data:ro \
  -v $(pwd)/backups:/backup \
  alpine tar czf /backup/agent-data.tar.gz /data
```

### Certificate Rotation

**Check certificate expiration:**

```bash
./scripts/rotate-certs.sh --check
```

**Rotate certificates:**

```bash
# Self-signed
./scripts/rotate-certs.sh --type self-signed --force

# Let's Encrypt
./scripts/rotate-certs.sh --type letsencrypt --domain your-domain.com --email admin@your-domain.com
```

**Automated rotation (cron):**

```bash
# Add to crontab
0 0 1 * * /path/to/wazuh-log-pipeline/scripts/rotate-certs.sh --type self-signed
```

### Log Management

**View logs:**

```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f nginx

# Last 100 lines
docker compose logs --tail=100 agent-ingest
```

**Log rotation:**

Nginx logs are automatically rotated by the container. For external log management:

```bash
# Configure logrotate
cat > /etc/logrotate.d/wazuh-api << EOF
/var/lib/docker/volumes/wazuh-log-pipeline_nginx-logs/_data/*.log {
    daily
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 root root
    sharedscripts
    postrotate
        docker exec wazuh-nginx nginx -s reopen
    endscript
}
EOF
```

### Updates

**Update containers:**

```bash
# Pull latest images
docker compose pull

# Rebuild custom images
docker compose build --no-cache

# Restart with new images
docker compose up -d
```

**Update with zero downtime:**

```bash
# Scale up new containers
docker compose up -d --scale agent-ingest=2 --no-recreate

# Wait for new container to be healthy
sleep 30

# Remove old container
docker compose up -d --scale agent-ingest=1
```

### Monitoring

**Health check endpoints:**

| Endpoint | Auth Required | Purpose |
|----------|---------------|---------|
| `/health/live` | No | Liveness probe |
| `/health/ready` | No | Readiness probe |
| `/api/health` | Yes | Detailed health |

**Metrics to monitor:**

- Container CPU/memory usage
- Request rate and latency
- Error rates (4xx, 5xx)
- Fail2ban ban count
- Certificate expiration

**Example monitoring script:**

```bash
#!/bin/bash
# health-check.sh

# Check liveness
if ! curl -sf -k https://localhost/health/live > /dev/null; then
    echo "CRITICAL: Service not alive"
    exit 2
fi

# Check readiness
if ! curl -sf -k https://localhost/health/ready > /dev/null; then
    echo "WARNING: Service not ready"
    exit 1
fi

# Check certificate expiration
DAYS=$(./scripts/rotate-certs.sh --check 2>&1 | grep "Days remaining" | awk '{print $NF}')
if [ "$DAYS" -lt 30 ]; then
    echo "WARNING: Certificate expires in $DAYS days"
    exit 1
fi

echo "OK: All checks passed"
exit 0
```

---

## Quick Reference

### Essential Commands

```bash
# Start services
docker compose up -d

# Stop services
docker compose down

# View logs
docker compose logs -f

# Restart service
docker compose restart nginx

# Check status
docker compose ps

# Execute command in container
docker compose exec agent-ingest /bin/bash
```

### API Endpoints

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| GET | `/health/live` | No | Liveness probe |
| GET | `/health/ready` | No | Readiness probe |
| GET | `/api/health` | Yes | Detailed health |
| PUT | `/api/` | Yes | Ingest single event |
| PUT | `/api/batch` | Yes | Ingest batch events |

### File Locations

| File | Purpose |
|------|---------|
| `secrets/api_key.txt` | API authentication key |
| `deploy/nginx/certs/` | TLS certificates |
| `.env` | Environment configuration |
| `docker-compose.yml` | Service definitions |

---

*For additional support, refer to the [Security Implementation Master Plan](../plans/SECURITY-IMPLEMENTATION-MASTER-PLAN.md) or contact the security team.*